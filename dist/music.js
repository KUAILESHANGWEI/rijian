const $ = selector => document.querySelector(selector);
let database;
let music;
let cloudMusic;
let context;
let buffer;
let source;
let enabled = false;
let loading = true;
let report;
let musicReady = Promise.resolve();

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('rijian-audio', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('settings');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error('请关闭其他日缄窗口后重试'));
  });
}
function readMusic() {
  return new Promise((resolve, reject) => {
    const request = database.transaction('settings').objectStore('settings').get('music');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
function saveMusic(value) {
  return new Promise((resolve, reject) => {
    const transaction = database.transaction('settings', 'readwrite');
    const store = transaction.objectStore('settings');
    if (value) store.put(value, 'music');
    else store.delete('music');
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}
function updateStatus() {
  $('#music-name').textContent = cloudMusic?.name || (music ? music.name : '尚未上传音乐');
  $('#music-enable').disabled = loading || (!music && !cloudMusic);
  $('#music-remove').disabled = loading || (!music && !cloudMusic);
  $('#music-upload').disabled = loading;
  $('#music-state').textContent = enabled ? '声音已启用，提醒音乐循环播放，点击“停止播放”结束。' : '操作 App 或保存提醒时自动准备声音。';
  $('#music-stop').disabled = !source;
}
export function stopMusic() {
  window.rijianNativeStopMusic?.();
  if (source) {
    const previous = source;
    source = null;
    previous.onended = null;
    previous.stop();
    previous.disconnect();
  }
  $('#music-playing').hidden = true;
  updateStatus();
}
function startPlayback(title, loop = false) {
  stopMusic();
  const playback = context.createBufferSource();
  playback.buffer = buffer;
  playback.loop = loop;
  playback.connect(context.destination);
  playback.onended = () => {
    if (source !== playback) return;
    source = null;
    playback.disconnect();
    $('#music-playing').hidden = true;
    updateStatus();
  };
  source = playback;
  $('#music-playing-title').textContent = title;
  $('#music-playing').hidden = false;
  playback.start();
  updateStatus();
}
export function playReminderMusic(title, {quiet = false, id = title} = {}) {
  if (window.rijianNativePlayReminder?.(title,id)) return true;
  if (!music) return false;
  if (!enabled || context?.state !== 'running' || !buffer) {
    enabled = false;
    updateStatus();
    if (!quiet) report('提醒已到，声音尚未准备好，请重新保存提醒或启用声音。');
    return false;
  }
  if (source) {
    source.loop = true;
    $('#music-playing-title').textContent = `日子提醒 · ${title}`;
    return true;
  }
  try { startPlayback(`日子提醒 · ${title}`, true); return true; }
  catch { enabled = false; updateStatus(); if (!quiet) report('音乐未能播放，请重新启用声音。'); return false; }
}
export async function prepareMusic() {
  try {
    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) return false;
    context ||= new AudioContext();
    const resumed = context.resume();
    await Promise.race([resumed,new Promise((_,reject)=>setTimeout(()=>reject(new Error('声音播放未获授权')),3000))]);
    await musicReady;
    if (!music) return false;
    if (!window.rijianNativeUploadMusic) buffer ||= await context.decodeAudioData(await music.file.arrayBuffer());
    if (context.state !== 'running') throw new Error('声音播放未获授权');
    enabled = true;
    updateStatus();
    return true;
  } catch (error) {
    enabled = false;
    updateStatus();
    report(`声音准备失败，${error.message}`);
    return false;
  }
}
export async function initializeMusic(toast) {
  window.rijianApplyCloudMusic = async value => {
    await musicReady;
    window.rijianCloudMusicDecision=true;
    cloudMusic=value;
    if(!value){music=null;buffer=null;enabled=false;void saveMusic(null).catch(()=>{});}
    updateStatus();
  };
  report = toast;
  $('#music-upload').onclick = () => $('#music-file').click();
  $('#music-file').onchange = async event => {
    const file = event.target.files[0];
    if (!file) return;
    loading = true;
    updateStatus();
    try {
      if (file.size > 200 * 1024 * 1024) throw new Error('请选择 200MB 以内的音乐');
      if (!database) throw new Error('音乐存储不可用，请检查存储权限');
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!AudioContext) throw new Error('当前设备暂不支持音乐提醒');
      context ||= new AudioContext();
      let decoded;
      if (window.rijianNativeUploadMusic) await window.rijianNativeUploadMusic(file);
      else { decoded = await context.decodeAudioData(await file.arrayBuffer()); if (!decoded.duration) throw new Error('音乐文件没有可播放内容'); }
      const next = {name: file.name, file};
      await saveMusic(next);
      stopMusic();
      music = next;
      cloudMusic=null;
      buffer = decoded;
      enabled = false;
      report('音乐已保存，请点击“启用声音并试听”。');
    } catch (error) { report(`上传失败，${error.message || '文件无法播放'}`); }
    finally { loading = false; event.target.value = ''; updateStatus(); }
  };
  $('#music-enable').onclick = async () => {
    try {
      if ((!music && !cloudMusic) || loading) return;
      if (window.rijianNativePreviewMusic?.()) return;
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!AudioContext) throw new Error('当前设备暂不支持音乐提醒');
      context ||= new AudioContext();
      await Promise.race([context.resume(), new Promise((_, reject) => setTimeout(() => reject(new Error('声音启动超时，请重试')), 3000))]);
      buffer ||= await context.decodeAudioData(await music.file.arrayBuffer());
      if (context.state !== 'running') throw new Error('声音播放未获授权');
      enabled = true;
      startPlayback('提醒音乐试听');
    } catch (error) { enabled = false; updateStatus(); report(`声音未启用，${error.message}`); }
  };
  $('#music-stop').onclick = stopMusic;
  $('#music-playing-stop').onclick = stopMusic;
  $('#music-remove').onclick = async () => {
    loading = true;
    updateStatus();
    try {
      await saveMusic(null);
      stopMusic();
      music = null;
      cloudMusic=null;
      buffer = null;
      enabled = false;
      report('提醒音乐已移除');
    } catch { report('移除失败，请检查存储权限'); }
    finally { loading = false; updateStatus(); }
  };
  musicReady = (async () => {
    try { database = await openDatabase(); music = await readMusic(); }
    catch { report('音乐存储暂时不可用，请检查存储权限'); }
    finally { loading = false; updateStatus(); }
  })();
  await musicReady;
  if(window.rijianPendingCloudMusic){const {value}=window.rijianPendingCloudMusic;delete window.rijianPendingCloudMusic;await window.rijianApplyCloudMusic(value);}
}
