import {prepareMusic} from './music.js?v=15';
const KEY = 'rijian-quick-timer';
const $ = selector => document.querySelector(selector);
const emptyTimer = {status:'idle',duration:300000,remaining:300000,deadline:null};
let timer = {...emptyTimer};
let notify;
let report;
let preparing = false;
function save() {
  try { sessionStorage.setItem(KEY,JSON.stringify(timer)); }
  catch { report('倒计时正在运行，计时进度暂时无法保存。'); }
}
function remainingTime() {
  return timer.status === 'running' ? Math.max(0,timer.deadline-Date.now()) : timer.remaining;
}
function formatTime(milliseconds) {
  const seconds = Math.ceil(milliseconds/1000);
  return [Math.floor(seconds/3600),Math.floor(seconds/60)%60,seconds%60].map(value=>String(value).padStart(2,'0')).join(':');
}
function restoreInputs() {
  const seconds = timer.duration/1000;
  $('#timer-hours').value = Math.floor(seconds/3600);
  $('#timer-minutes').value = Math.floor(seconds/60)%60;
  $('#timer-seconds').value = seconds%60;
}
function render() {
  const active = ['running','paused'].includes(timer.status);
  $('#timer-display').textContent = formatTime(remainingTime());
  $('#timer-state').textContent = {idle:'设置时长后开始',running:'倒计时进行中',paused:'已暂停',done:'时间到！'}[timer.status];
  for (const id of ['timer-start','timer-pause','timer-reset']) $(`#${id}`).disabled = preparing;
  $('#timer-start').textContent = preparing ? '准备中…' : '开始';
  $('#timer-start').hidden = active;
  $('#timer-pause').hidden = !active;
  $('#timer-pause').textContent = timer.status === 'paused' ? '继续' : '暂停';
  document.querySelectorAll('#timer-form input').forEach(input=>input.disabled=active || preparing);
  $('#timer-short-status').textContent = active ? `${formatTime(remainingTime())}${timer.status==='paused'?' · 已暂停':''}` : timer.status==='done'?'时间到':'';
}
function tick() {
  if (timer.status === 'running' && remainingTime() === 0) {
    timer = {...timer,status:'done',remaining:0,deadline:null};
    save();
    notify('倒计时结束，时间到！');
  }
  render();
}
export function initializeTimer(onFinished, onError) {
  notify = onFinished;
  report = onError;
  try {
    const saved = JSON.parse(sessionStorage.getItem(KEY));
    if (saved && ['idle','running','paused','done'].includes(saved.status) && Number.isFinite(saved.duration) && saved.duration>0 && saved.duration<=359999000 && Number.isFinite(saved.remaining) && saved.remaining>=0 && saved.remaining<=saved.duration && (saved.status!=='running'||Number.isFinite(saved.deadline))) timer = saved;
  } catch { /* Start with the default duration when no valid timer exists. */ }
  restoreInputs();
  $('#countdown').onclick = () => { tick(); $('#timer-error').textContent=''; $('#timer-dialog').showModal(); };
  $('#timer-form').onsubmit = async event => {
    event.preventDefault();
    const values = ['hours','minutes','seconds'].map(name=>Number($(`#timer-${name}`).value));
    if (values.some(value=>!Number.isInteger(value)||value<0) || values[0]>99 || values[1]>59 || values[2]>59) {
      $('#timer-error').textContent='请输入有效的时、分、秒';
      return;
    }
    const duration = (values[0]*3600+values[1]*60+values[2])*1000;
    if (!duration) { $('#timer-error').textContent='倒计时时长须大于 0'; return; }
    preparing = true;
    render();
    await prepareMusic();
    preparing = false;
    timer = {status:'running',duration,remaining:duration,deadline:Date.now()+duration};
    $('#timer-error').textContent='';
    save();
    render();
  };
  $('#timer-pause').onclick = async () => {
    if (timer.status === 'running') {
      tick();
      if (timer.status !== 'running') return;
      timer = {...timer,status:'paused',remaining:remainingTime(),deadline:null};
    } else if (timer.status === 'paused') {
      preparing = true;
      render();
      await prepareMusic();
      preparing = false;
      timer = {...timer,status:'running',deadline:Date.now()+timer.remaining};
    }
    save();
    render();
  };
  $('#timer-reset').onclick = () => {
    timer = {...timer,status:'idle',remaining:timer.duration,deadline:null};
    save();
    restoreInputs();
    $('#timer-error').textContent='';
    render();
  };
  $('#timer-form').oninput = () => {
    if (timer.status==='running'||timer.status==='paused') return;
    const seconds = Number($('#timer-hours').value)*3600+Number($('#timer-minutes').value)*60+Number($('#timer-seconds').value);
    if (Number.isInteger(seconds) && seconds > 0 && seconds <= 359999) {
      timer = {status:'idle',duration:seconds*1000,remaining:seconds*1000,deadline:null};
      save();
      render();
    }
  };
  tick();
  setInterval(tick,250);
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)tick();});
}
