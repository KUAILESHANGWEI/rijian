const $ = selector => document.querySelector(selector);
let database;
let music;
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
  $('#music-name').textContent = music ? music.name : '尚未上传音乐';
  $('#music-enable').disabled = loading || !music;
  $('#music-remove').disabled = loading || !music;
  $('#music-upload').disabled = loading;
  $('#music-state').textContent = enabled ? '声音已启用。到期时播放所选音乐，最长 60 秒。' : '倒计时点击“开始”或“继续”会自动准备声音。日子提醒可点击“启用声音并试听”。';
  $('#music-stop').disabled = !source;
}
export function stopMusic() {
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
function startPlayback(title) {
  stopMusic();
  const playback = context.createBufferSource();
  playback.buffer = buffer;
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
  playback.start(0, 0, Math.min(buffer.duration, 60));
  updateStatus();
}
export function playReminderMusic(title) {
  if (!music) return;
  if (!enabled || context?.state !== 'running' || !buffer) {
    enabled = false;
    updateStatus();
    report('提醒已到，请在备份与设置中点击“启用声音并试听”。');
    return;
  }
  if (source) {
    $('#music-playing-title').textContent = `日子提醒 · ${title}`;
    return;
  }
  try { startPlayback(`日子提醒 · ${title}`); }
  catch { enabled = false; updateStatus(); report('音乐未能播放，请重新启用声音。'); }
}
export async function prepareMusic() {
  try {
    const AudioContext = window.AudioContext || window.webkitAudioContext;
    if (!AudioContext) return false;
    context ||= new AudioContext();
    const resumed = context.resume();
    await Promise.race([resumed,new Promise((_,reject)=>setTimeout(()=>reject(new Error('浏览器未允许播放声音')),3000))]);
    await musicReady;
    if (!music) return false;
    buffer ||= await context.decodeAudioData(await music.file.arrayBuffer());
    if (context.state !== 'running') throw new Error('浏览器未允许播放声音');
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
  report = toast;
  $('#music-upload').onclick = () => $('#music-file').click();
  $('#music-file').onchange = async event => {
    const file = event.target.files[0];
    if (!file) return;
    loading = true;
    updateStatus();
    try {
      if (file.size > 30 * 1024 * 1024) throw new Error('请选择 30MB 以内的音乐');
      if (!database) throw new Error('浏览器音乐存储不可用，请检查网站存储权限');
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!AudioContext) throw new Error('当前浏览器不支持音乐提醒');
      context ||= new AudioContext();
      const decoded = await context.decodeAudioData(await file.arrayBuffer());
      if (!decoded.duration) throw new Error('音乐文件没有可播放内容');
      const next = {name: file.name, file};
      await saveMusic(next);
      stopMusic();
      music = next;
      buffer = decoded;
      enabled = false;
      report('音乐已保存，请点击“启用声音并试听”。');
    } catch (error) { report(`上传失败，${error.message || '文件无法播放'}`); }
    finally { loading = false; event.target.value = ''; updateStatus(); }
  };
  $('#music-enable').onclick = async () => {
    try {
      if (!music || loading) return;
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!AudioContext) throw new Error('当前浏览器不支持音乐提醒');
      context ||= new AudioContext();
      await context.resume();
      buffer ||= await context.decodeAudioData(await music.file.arrayBuffer());
      if (context.state !== 'running') throw new Error('浏览器未允许播放声音');
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
      buffer = null;
      enabled = false;
      report('提醒音乐已移除');
    } catch { report('移除失败，请检查浏览器存储权限'); }
    finally { loading = false; updateStatus(); }
  };
  musicReady = (async () => {
    try { database = await openDatabase(); music = await readMusic(); }
    catch { report('音乐存储暂时不可用，请检查浏览器存储权限'); }
    finally { loading = false; updateStatus(); }
  })();
  await musicReady;
}
