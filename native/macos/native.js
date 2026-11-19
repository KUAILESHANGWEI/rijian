(async () => {
  const isApple = !!window.webkit?.messageHandlers?.rijian;
  const isMac = !!window.rijianMac;
  let nativeStatus = {};
  let revision = 0;
  let lastSnapshot = '';
  const {nextOccurrence} = await import('./dates.js');
  function send(message) {
    if (isApple) window.webkit.messageHandlers.rijian.postMessage(message);
    else if (window.RijianAndroid) window.RijianAndroid.send(JSON.stringify(message));
  }
  function reminders(events) {
    const now = Date.now();
    const queue = [];
    function add(event, from) {
      const lead = event.reminderMinutes * 60000;
      let date = nextOccurrence(event, new Date(from + lead));
      if (!date) return;
      if (date.getTime() - lead <= now) {
        if (event.repeatType === '从不') return;
        const cursor = new Date(date);
        cursor.setDate(cursor.getDate() + 1);
        date = nextOccurrence(event, cursor);
      }
      if (!date || date.getTime() - lead <= now) return;
      queue.push({event,date,time:date.getTime()-lead});
    }
    for (const event of events) if (!event.isArchived && event.reminderMinutes >= 0) add(event,now);
    const result = [];
    while (queue.length && result.length < 60) {
      queue.sort((a,b)=>a.time-b.time);
      const item = queue.shift();
      result.push({key:`${item.event.id}-${item.date.getTime()}-${item.event.reminderMinutes}`,title:item.event.title,time:item.time});
      if (item.event.repeatType !== '从不') {
        const cursor = new Date(item.date);
        cursor.setDate(cursor.getDate()+1);
        add(item.event,cursor.getTime()-item.event.reminderMinutes*60000);
      }
    }
    return result;
  }
  function sync(force = false) {
    try {
      const raw = localStorage.getItem('jian-data-v1');
      const timer = sessionStorage.getItem('rijian-quick-timer');
      if (!raw || (!force && raw + timer === lastSnapshot)) return;
      lastSnapshot = raw + timer;
      const state = JSON.parse(raw);
      const parsedTimer = timer ? JSON.parse(timer) : null;
      const requests = reminders(state.events);
      if (parsedTimer?.status === 'running' && parsedTimer.deadline > Date.now()) requests.unshift({key:'timer-quick',title:'倒计时结束',time:parsedTimer.deadline});
      send({action:'sync',snapshot:JSON.stringify({version:1,exportedAt:new Date().toISOString(),...state}),requests});
    } catch (error) { console.error('Native reminder sync failed',error.message); }
  }
  window.rijianNativeCommit = () => queueMicrotask(()=>sync());
  window.rijianNativeStatus = status => {
    nativeStatus = status;
    const permission = document.querySelector('#permission-status');
    if (permission) permission.textContent = status.reminderStatus || '正在读取提醒状态…';
    const backup = document.querySelector('#cloud-backup-status');
    if (backup) backup.textContent = status.backupStatus || '尚未选择 iCloud 备份目录';
    const interval = document.querySelector('#cloud-backup-interval');
    if (interval && document.activeElement !== interval) interval.value = String(status.backupDays || 1);
    const enabled = document.querySelector('#cloud-backup-enabled');
    if (enabled) enabled.checked = !!status.backupEnabled;
    const playing = document.querySelector('#music-playing');
    if (status.previewing) {
      document.querySelector('#music-playing-title').textContent = '提醒音乐试听';
      playing.hidden = false;
    } else if (!status.playing && document.querySelector('#music-playing-title').textContent !== '提醒音乐试听') playing.hidden = true;
    if (isApple) { document.querySelector('#music-stop').disabled = !status.playing; if (!status.playing) playing.hidden = true; }
  };
  window.rijianNativePlayReminder = (title,key) => {
    if (!nativeStatus.remindersEnabled) return false;
    send({action:'playAlarm',title,key:key || title});
    document.querySelector('#music-playing-title').textContent = `日子提醒 · ${title}`;
    document.querySelector('#music-playing').hidden = false;
    return true;
  };
  if (isApple) window.rijianNativePreviewMusic = () => {
    send({action:'previewMusic'});
    return true;
  };
  window.rijianNativeStopMusic = () => send({action:'stopAlarm'});
  const settings = document.querySelector('#preferences .preferences-grid');
  const section = document.createElement('section');
  section.className='preferences-section';
  section.innerHTML = isApple ? '<h3>iCloud 自动备份</h3><label class="check"><input id="cloud-backup-enabled" type="checkbox">定期自动备份</label><div class="settings-actions"><button id="cloud-backup-folder">选择 iCloud 目录</button><button id="cloud-backup-now">立即备份</button><select id="cloud-backup-interval" aria-label="自动备份周期"><option value="1">每天</option><option value="7">每周</option><option value="30">每30天</option></select></div><p id="cloud-backup-status"></p><p>后台执行由系统安排，打开 App 会补做逾期备份。音乐文件请单独保存。</p>' : '<h3>后台提醒</h3><button id="exact-alarm-settings">允许准时提醒</button><p>请开启通知与准时提醒权限，以便后台响铃。</p>';
  settings.append(section);
  if (isMac) section.querySelector('p:last-child').textContent = 'App 运行时定期备份；再次打开会补做逾期备份。音乐文件请单独保存。';
  document.querySelector('#permission').textContent = '开启后台提醒';
  if (isApple) {
    document.querySelector('#cloud-backup-folder').onclick=()=>send({action:'chooseBackupFolder'});
    document.querySelector('#cloud-backup-now').onclick=()=>{sync(true);send({action:'backupNow'});};
    const configure=()=>send({action:'configureBackup',enabled:document.querySelector('#cloud-backup-enabled').checked,days:Number(document.querySelector('#cloud-backup-interval').value)});
    document.querySelector('#cloud-backup-enabled').onchange=configure;
    document.querySelector('#cloud-backup-interval').onchange=configure;
  } else document.querySelector('#exact-alarm-settings').onclick=()=>send({action:'exactAlarmSettings'});
  document.addEventListener('click',event=>{
    if (event.target.closest('#settings')) { send({action:'status'}); return; }
    if (event.target.closest('#permission')) {event.preventDefault();event.stopImmediatePropagation();send({action:'requestReminders'});return;}
    if (event.target.closest('#music-remove')) send({action:'removeMusic'});
    if (!event.target.closest('#export')) return;
    event.preventDefault();event.stopImmediatePropagation();
    try {
      const state=JSON.parse(localStorage.getItem('jian-data-v1'));
      const date=new Date();
      const stamp=[date.getFullYear(),String(date.getMonth()+1).padStart(2,'0'),String(date.getDate()).padStart(2,'0')].join('-');
      send({action:'export',filename:`日缄-备份-${stamp}.json`,content:JSON.stringify({version:1,exportedAt:new Date().toISOString(),...state},null,2)});
    } catch(error) {alert(`导出失败，${error.message}`);}
  },true);
  document.addEventListener('submit',event=>{
    if (event.target.id==='event-form' && Number(event.target.elements.reminderMinutes.value)>=0 || event.target.id==='timer-form') send({action:'requestReminders'});
  },true);
  let transferSequence = 0;
  const transfers = new Map();
  window.rijianNativeMusicResult = (id,error) => {
    const pending=transfers.get(id); if(!pending)return;
    transfers.delete(id);clearTimeout(pending.timeout);
    error ? pending.reject(new Error(error)) : pending.resolve();
  };
  window.rijianNativeUploadMusic = async file => {
    if(file.size>200*1024*1024)throw new Error('请选择 200MB 以内的音乐');
    const transfer=String(Date.now())+'-'+(++transferSequence);
    for(let offset=0;offset<file.size;offset+=1024*1024){
      const bytes=new Uint8Array(await file.slice(offset,offset+1024*1024).arrayBuffer());
      let binary='';for(let n=0;n<bytes.length;n+=8192)binary+=String.fromCharCode(...bytes.subarray(n,n+8192));
      const callback=transfer+'-'+offset;
      await new Promise((resolve,reject)=>{
        const timeout=setTimeout(()=>{transfers.delete(callback);reject(new Error('音乐保存超时，请重试'));},120000);
        transfers.set(callback,{resolve,reject,timeout});
        send({action:'musicChunk',transfer,callback,name:file.name,offset,total:file.size,final:offset+bytes.length>=file.size,data:btoa(binary)});
      });
    }
  };
  // Migrate music already uploaded in an earlier installation.
  try {
    const database=await new Promise((resolve,reject)=>{const request=indexedDB.open('rijian-audio',1);request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);request.onupgradeneeded=()=>request.result.createObjectStore('settings');});
    const saved=await new Promise((resolve,reject)=>{const request=database.transaction('settings').objectStore('settings').get('music');request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
    if(saved?.file) await window.rijianNativeUploadMusic(saved.file);
    database.close();
  } catch { /* Music can also be uploaded again from settings. */ }
  sync(true);send({action:'status'});
  setInterval(()=>sync(),1000);
  addEventListener('focus',()=>{sync(true);send({action:'status'});});
})();
