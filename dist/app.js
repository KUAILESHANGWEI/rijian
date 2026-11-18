import {initializeMusic,playReminderMusic} from './music.js?v=6';
import {dateInput,dayDifference,nextOccurrence,validateEvent} from './dates.js?v=6'
import { Lunar, Solar } from './vendor/lunar.js?v=6';
const $ = s => document.querySelector(s);
const KEY = 'jian-data-v1';
const defaultLabels = ['生日','纪念日','工作'];
const icons = ['<path d="M8 6h12M8 12h12M8 18h12M3 6h.1M3 12h.1M3 18h.1"/>','<path d="M4 20V10h16v10zM4 15h16M8 10V5m4 5V3m4 7V5"/>','<path d="M20 5c-3-3-6-1-8 1-2-2-5-4-8-1-5 5 8 15 8 15S25 10 20 5z"/>','<rect x="3" y="7" width="18" height="14" rx="2"/><path d="M8 7V3h8v4M3 12h18"/>','<path d="M4 7h16v14H4zM3 3h18v4H3zM9 11h6"/>'];
let state;
let loadFailed = false;
try {
  const saved = localStorage.getItem(KEY);
  if (saved) {
    const parsed = JSON.parse(saved);
    if (!Array.isArray(parsed.events) || !Array.isArray(parsed.labels)) throw new Error('数据格式异常');
    state = {...parsed, events:parsed.events.map(validateEvent)};
  } else {
    const sample = [['冬日旅行','🌿',32,'纪念日'],['妈妈的生日','🎂',16,'生日'],['结婚纪念日','❤️',28,'纪念日'],['新年','🎇',43,'纪念日'],['阅读计划','📖',12,'工作']];
    state = {events:sample.map(([title,emoji,days,label]) => {
      const date = new Date();date.setDate(date.getDate()+days);date.setHours(9,0,0,0);
      return validateEvent({title,emoji,label,targetDate:date.getTime()});
    }), labels:defaultLabels, notified:[]};
    localStorage.setItem(KEY,JSON.stringify(state));
  }
} catch {
  state = {events:[],labels:defaultLabels,notified:[]};loadFailed = true;
}
let category='全部日子',tab='all',query='';
let toastTimer;
function toast(text) { $('#toast').textContent=text;$('#toast').style.display='block';clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').style.display='none',5000); }
function persist(next) {
  try { localStorage.setItem(KEY,JSON.stringify(next));state=next;return true; }
  catch {toast('保存失败，浏览器存储空间或权限不足。请先导出备份。');return false;}
}
function escapeHtml(value) {return String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
const formatDate = date => new Intl.DateTimeFormat('zh-CN',{year:'numeric',month:'long',day:'numeric'}).format(date);
function eventDate(event,date) {return `${event.isLunar?`农历${event.isLunarLeap?'闰':''}${event.lunarMonth}月${event.lunarDay}日 · `:''}${date?formatDate(date):'未来 23 年内无此农历日期'}`;}
function countMarkup(date,featured=false) {
  if (!date) return '待定';
  const days = dayDifference(date);
  if (featured) return `<p>${days<0?'已经过去':days===0?'就是今天':'还有'}</p><span class="days">${Math.abs(days)}</span> <small>天</small>`;
  return `${days<0?'已过':days===0?'今天':'还有'} <strong>${Math.abs(days)}</strong> 天`;
}
function render() {
  $('#today').textContent = new Intl.DateTimeFormat('zh-CN',{year:'numeric',month:'long',day:'numeric',weekday:'long'}).format(new Date());
  const labels = [...new Set([...groupNames(),'未分组'])];
  const categories=['全部日子',...labels,'已归档'];
  $('#categories').innerHTML=categories.map((name,i)=>`<button data-category="${escapeHtml(name)}" class="${name===category?'active':''}" aria-pressed="${name===category}"><span class="nav-icon"><svg viewBox="0 0 24 24">${icons[Math.min(i,4)]}</svg></span>${escapeHtml(name)}</button>`).join('');
  const selectedLabel = $('#event-form').elements.label.value;
  $('#label-options').innerHTML=labels.map(l=>`<option value="${escapeHtml(l)}">${escapeHtml(l)}</option>`).join('');
  if (labels.includes(selectedLabel)) $('#event-form').elements.label.value = selectedLabel;
  const active=state.events.filter(e=>category==='已归档'?e.isArchived:!e.isArchived).filter(e=>['全部日子','已归档'].includes(category)||e.label===category).map(event=>({event,date:nextOccurrence(event)}));
  const featured=active.filter(e=>e.date&&dayDifference(e.date)>=0).sort((a,b)=>a.date-b.date)[0];
  $('#featured').hidden=!featured || category==='已归档';
  if (featured) {
    $('#featured').innerHTML=`<div><h2>${escapeHtml(featured.event.title)}</h2><p>${escapeHtml(eventDate(featured.event,featured.date))}</p></div><div class="feature-count">${countMarkup(featured.date,true)}</div>`;
    $('#featured').onclick=()=>openEditor(featured.event.id);
    $('#featured').tabIndex=0;$('#featured').onkeydown=e=>{if(e.key==='Enter')openEditor(featured.event.id);};
  }
  const filtered=active.filter(({event,date})=>(event.title+' '+event.notes).toLowerCase().includes(query.toLowerCase())&&(tab==='all'||(date&&(tab==='future'?dayDifference(date)>=0:dayDifference(date)<0)))).sort((a,b)=>(a.date?.getTime()??Infinity)-(b.date?.getTime()??Infinity));
  $('#events').innerHTML=filtered.length?filtered.map(({event,date})=>`<button class="event-row" data-id="${escapeHtml(event.id)}" aria-label="编辑${escapeHtml(event.title)}"><span class="emoji">${escapeHtml(event.emoji)}</span><span class="event-info"><span class="event-title">${escapeHtml(event.title)}</span><span class="event-meta"><span class="label">${escapeHtml(event.label)}</span>${escapeHtml(eventDate(event,date))}</span></span><span class="event-count">${countMarkup(date)}</span></button>`).join(''):'<div class="empty">这里还没有日子，记下一个值得期待的时刻吧。</div>';
  $('#tabs').querySelectorAll('button').forEach(b=>{b.classList.toggle('selected',b.dataset.tab===tab);b.setAttribute('aria-pressed',String(b.dataset.tab===tab));});
}
function openEditor(id) {
  const event=state.events.find(e=>e.id===id);const form=$('#event-form');form.reset();
  form.elements.id.value=event?.id||'';
  if (!event) form.elements.label.value = groupNames()[0] || '未分组';
  $('#editor-title').textContent=event?'编辑日子':'记一笔';
  for(const name of ['title','emoji','label','repeatType','reminderMinutes','notes','repeatEvery','repeatUnit']) if(event)form.elements[name].value=event[name] ?? (name==='repeatEvery'?1:'day');
  for(const name of ['isLunar','isLunarLeap'])form.elements[name].checked=event?.[name]||false;
  const date = new Date(event?.targetDate || Date.now());
  if (!event) date.setHours(9,0,0,0);
  const lunar = Solar.fromDate(date).getLunar();
  form.elements.entryYear.value = event?.isLunar ? lunar.getYear() : date.getFullYear();
  form.elements.entryMonth.value = event?.isLunar ? event.lunarMonth : date.getMonth()+1;
  form.elements.entryDay.value = event?.isLunar ? event.lunarDay : date.getDate();
  form.elements.entryHour.value = date.getHours();
  form.elements.entryMinute.value = date.getMinutes();
  updateCalendarMode();
  $('#custom-repeat').hidden = form.elements.repeatType.value !== '自定义';
  $('#emoji-picker').hidden = true;
  $('#emoji-toggle').setAttribute('aria-expanded','false');
  $('#delete').hidden=!event;$('#archive').hidden=!event;$('#archive').textContent=event?.isArchived?'取消归档':'归档';$('#form-error').textContent='';$('#editor').showModal();
}
function groupNames() {
  return [...new Set([...state.labels,...state.events.map(event=>event.label)])];
}
function validGroupName(value) {
  const name = String(value || '').trim();
  if (!name || name.length > 30) throw new Error('分组名称须为 1 至 30 个字符');
  if (['全部日子','已归档'].includes(name)) throw new Error('请使用其他分组名称');
  return name;
}
function renderGroups() {
  $('#group-list').innerHTML = groupNames().filter(name=>name!=='未分组').map(name=>`<form class="group-row" data-group="${escapeHtml(name)}"><input name="name" aria-label="${escapeHtml(name)}的新名称" value="${escapeHtml(name)}" maxlength="30" required><button type="submit">保存</button><button type="button" data-delete-group="${escapeHtml(name)}" class="danger" aria-label="删除分组${escapeHtml(name)}">删除</button></form>`).join('') || '<p class="group-hint">还没有分组，可以在下方新增。</p>';
}
$('#manage-groups').onclick = () => {
  $('#group-error').textContent = '';
  renderGroups();
  $('#groups').showModal();
};
$('#group-list').onsubmit = event => {
  event.preventDefault();
  const form = event.target;
  const previous = form.dataset.group;
  try {
    const name = validGroupName(form.elements.name.value);
    if (name === '未分组') throw new Error('“未分组”用于收纳删除分组后的日子，请使用其他名称');
    if (name !== previous && groupNames().includes(name)) throw new Error('这个分组名称已存在');
    const next = {...state,labels:groupNames().map(label=>label===previous?name:label),events:state.events.map(item=>item.label===previous?{...item,label:name}:item)};
    if (!persist(next)) return;
    if (category === previous) category = name;
    $('#group-error').textContent = '';
    render();
    renderGroups();
    toast('分组名称已保存');
  } catch (error) { $('#group-error').textContent = error.message; }
};
$('#group-list').onclick = event => {
  const button = event.target.closest('[data-delete-group]');
  if (!button) return;
  const name = button.dataset.deleteGroup;
  if (!confirm(`删除“${name}”分组？组内日子会移至“未分组”。`)) return;
  const next = {...state,labels:groupNames().filter(label=>label!==name),events:state.events.map(item=>item.label===name?{...item,label:'未分组'}:item)};
  if (!persist(next)) return;
  if (category === name) category = '全部日子';
  $('#group-error').textContent = '';
  render();
  renderGroups();
  toast('分组已删除');
};
$('#new-group-form').onsubmit = event => {
  event.preventDefault();
  try {
    const name = validGroupName(event.target.elements.name.value);
    if (name === '未分组' || groupNames().includes(name)) throw new Error('这个分组名称已存在或为保留名称');
    if (!persist({...state,labels:[...groupNames(),name]})) return;
    event.target.reset();
    $('#group-error').textContent = '';
    render();
    renderGroups();
    toast('分组已新增');
  } catch (error) { $('#group-error').textContent = error.message; }
};
$('#categories').onclick=e=>{const b=e.target.closest('[data-category]');if(b){category=b.dataset.category;render();}};
$('#events').onclick=e=>{const b=e.target.closest('[data-id]');if(b)openEditor(b.dataset.id);};
$('#tabs').onclick=e=>{if(e.target.dataset.tab){tab=e.target.dataset.tab;render();}};
$('#search').oninput=e=>{query=e.target.value;render();};
const emojiLibrary = {
  '表情人物': ['😀','😃','😄','😁','😆','😅','😂','🤣','🙂','🙃','😉','😊','😇','🥰','😍','🤩','😘','😋','😎','🥳','🤗','🤔','🤫','🫡','😴','🥹','😭','😤','👍','👏','🙌','🙏','💪','🫶','👋','🤝','👶','👧','👦','👩','👨','👵','👴','🧑‍🎓','🧑‍🍳','🧑‍💻','🧑‍⚕️','👑'],
  '动物自然': ['🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷','🐸','🐵','🐔','🐧','🐦','🦆','🦉','🦋','🐝','🐞','🐢','🐬','🐳','🐟','🐙','🦀','🦄','🌵','🌲','🌳','🌴','🍁','🍂','🌷','🌹','🌺','🌻','🌼','🪷','🌈','❄️','🔥','🌊','🌦️','⛄'],
  '美食饮品': ['🍏','🍎','🍐','🍊','🍋','🍌','🍉','🍇','🍓','🫐','🍒','🍑','🥭','🍍','🥑','🥦','🌽','🥕','🍞','🥐','🥯','🧀','🥚','🥞','🍔','🍟','🍕','🌮','🥟','🍜','🍝','🍣','🍙','🍱','🍰','🧁','🍩','🍪','🍫','🍬','🍭','🍦','🧋','🫖','🍵','🥛','🍹','🍷'],
  '节日庆祝': ['🎂','🎉','🎊','🎈','🎁','🎀','🎆','🎇','🧨','🧧','🏮','🥮','🥟','🎄','🎅','🦌','⛄','🎃','👻','💝','💘','💐','💍','👰','🤵','🥂','🍾','🕯️','🎓','🏆','🥇','🏅'],
  '运动爱好': ['⚽','🏀','🏈','⚾','🎾','🏐','🏓','🏸','🏒','🏹','🥊','🛹','🎣','🤿','🎿','🏂','🏋️','🚴','🏊','🧘','🎮','🎲','♟️','🧩','🎨','🎭','🎤','🎧','🎹','🎸','🎻','🥁','📷','🎬','📺','📚','✍️','🪴','🧵','🧶'],
  '出行地点': ['✈️','🚀','🛸','🚁','🚂','🚄','🚇','🚌','🚗','🚕','🚲','🛵','⛵','🚢','🗺️','🧭','🧳','🎒','⛺','🏕️','🏖️','🏝️','🏔️','⛰️','🌋','🏜️','🏞️','🌅','🌄','🌃','🏙️','🏡','🏢','🏫','🏥','🏦','🏛️','⛩️','🗽','🗼'],
  '物品符号': ['⌚','⏰','⏳','📅','🗓️','📌','📍','✂️','📎','🔑','🔒','💡','🔋','💻','⌨️','📱','☎️','🖨️','💾','💿','📦','✉️','📨','📬','📝','📓','📔','💵','💰','💳','💎','🛍️','🛒','🧸','🛏️','🛋️','🛁','🧹','❤️','🧡','💛','💚','💙','💜','🤎','🖤','🤍','💯','✅','❌','⚠️','♻️','🔔','🎵','∞','⭐'],
  '常用': ['🌿','🎂','❤️','🎉','🎁','⭐','📅','📖','🌸','☀️','🌙','✨','😊','🥰','🎈','🎇'],
  '生活': ['🏠','👪','👶','🐱','🐶','🌱','🍀','🌻','☕','🍰','🍎','🍜','🛒','💊','🏃','💤'],
  '纪念': ['💍','💐','💕','💌','🥂','🎓','🏆','🎊','🕯️','🎄','🧧','🏮','🎆','🎀','🎵','📷'],
  '工作旅行': ['💼','💻','📝','📚','📌','⏰','💰','💳','✈️','🚄','🚗','🏕️','🏖️','⛰️','🧳','🌍']
};
function renderEmojiLibrary(category = '常用') {
  $('#emoji-categories').innerHTML = Object.keys(emojiLibrary).map(name=>`<button type="button" data-emoji-category="${name}" aria-pressed="${name===category}" class="${name===category?'selected':''}">${name}</button>`).join('');
  $('#emoji-grid').innerHTML = emojiLibrary[category].map(emoji=>`<button type="button" data-emoji="${emoji}" aria-label="选择 ${emoji}">${emoji}</button>`).join('');
}
$('#emoji-input').onclick = () => {
  $('#emoji-picker').hidden = false;
  $('#emoji-toggle').setAttribute('aria-expanded','true');
  renderEmojiLibrary();
};
$('#emoji-toggle').onclick = () => {
  const open = $('#emoji-picker').hidden;
  $('#emoji-picker').hidden = !open;
  $('#emoji-toggle').setAttribute('aria-expanded',String(open));
  if (open) renderEmojiLibrary();
};
$('#emoji-categories').onclick = event => {
  const button = event.target.closest('[data-emoji-category]');
  if (button) renderEmojiLibrary(button.dataset.emojiCategory);
};
$('#emoji-grid').onclick = event => {
  const button = event.target.closest('[data-emoji]');
  if (!button) return;
  $('#event-form').elements.emoji.value = button.dataset.emoji;
  $('#emoji-picker').hidden = true;
  $('#emoji-toggle').setAttribute('aria-expanded','false');
  $('#emoji-toggle').focus();
};
$('#add').onclick=()=>openEditor();
$('#event-form').elements.repeatType.onchange = event => { $('#custom-repeat').hidden = event.target.value !== '自定义'; };
function updateCalendarMode() {
  const lunar = $('#event-form').elements.isLunar.checked;
  $('#leap-field').hidden = !lunar;
  $('#event-form').elements.entryDay.max = lunar ? 30 : 31;
  $('#calendar-mode').querySelectorAll('button').forEach(button => {
    const selected = (button.dataset.calendar === 'lunar') === lunar;
    button.classList.toggle('selected',selected);
    button.setAttribute('aria-pressed',String(selected));
  });
  $('#calendar-hint').textContent = lunar ? '按农历填写年月日，闰月请勾选。时间为 24 小时制。' : '按公历填写年月日，时间为 24 小时制。';
}
$('#calendar-mode').onclick = event => {
  const button = event.target.closest('[data-calendar]');
  if (!button) return;
  $('#event-form').elements.isLunar.checked = button.dataset.calendar === 'lunar';
  updateCalendarMode();
};
$('#event-form').onsubmit=e=>{
  e.preventDefault();const form=e.target;const raw=Object.fromEntries(new FormData(form));const existing=state.events.find(x=>x.id===raw.id);
  try {
    raw.label = validGroupName(raw.label);
    const year = Number(raw.entryYear);
    const month = Number(raw.entryMonth);
    const day = Number(raw.entryDay);
    const hour = Number(raw.entryHour);
    const minute = Number(raw.entryMinute);
    let target = new Date(year,month-1,day,hour,minute);
    if (form.elements.isLunar.checked) {
      const solar = Lunar.fromYmd(year,form.elements.isLunarLeap.checked?-month:month,day).getSolar();
      target = new Date(solar.getYear(),solar.getMonth()-1,solar.getDay(),hour,minute);
    } else if (target.getFullYear() !== year || target.getMonth() !== month-1 || target.getDate() !== day) {
      throw new Error('这个公历日期不存在，请检查年月日');
    }
    const event=validateEvent({...existing,...raw,id:raw.id||crypto.randomUUID(),targetDate:target.getTime(),lunarMonth:month,lunarDay:Math.min(day,30),isLunar:form.elements.isLunar.checked,isLunarLeap:form.elements.isLunarLeap.checked,repeatType:raw.repeatType});
    if(event.isLunar&&!nextOccurrence(event))throw new Error('无法匹配这个农历日期，请检查公历年份、农历月日和闰月。');
    const events=existing?state.events.map(x=>x.id===event.id?event:x):[...state.events,event];
    if(persist({...state,events,labels:[...new Set([...state.labels,event.label])]})){ $('#editor').close();render();toast('日子已保存');checkReminders(); }
  } catch(error){$('#form-error').textContent=error.message;}
};
$('#delete').onclick=()=>{const id=$('#event-form').elements.id.value;if(confirm('确定删除这个日子？')&&persist({...state,events:state.events.filter(x=>x.id!==id)})){$('#editor').close();render();toast('已删除');}};
$('#archive').onclick=()=>{const id=$('#event-form').elements.id.value;if(persist({...state,events:state.events.map(x=>x.id===id?{...x,isArchived:!x.isArchived}:x)})){$('#editor').close();render();toast('已更新归档状态');}};
document.querySelectorAll('.close').forEach(b=>b.onclick=()=>b.closest('dialog').close());
function permissionStatus(){const status= !('Notification' in window)?'当前浏览器不支持系统通知':Notification.permission==='granted'?'浏览器通知已开启':Notification.permission==='denied'?'通知已被阻止，可在浏览器的网站设置中调整':'浏览器通知尚未开启';$('#permission-status').textContent=status;return status;}
$('#settings').onclick=()=>{permissionStatus();$('#preferences').showModal();};
$('#permission').onclick=async()=>{try{if('Notification' in window)await Notification.requestPermission();permissionStatus();}catch{toast('此环境暂时无法开启通知');}};
$('#export').onclick=()=>{const blob=new Blob([JSON.stringify({version:1,exportedAt:new Date().toISOString(),...state},null,2)],{type:'application/json'});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download=`日缄-备份-${dateInput(new Date()).slice(0,10)}.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
$('#import').onclick=()=>$('#file').click();
$('#file').onchange=async e=>{
  const file=e.target.files[0];if(!file)return;
  try {
    if(file.size>10*1024*1024)throw new Error('备份文件不能超过 10MB');
    const data=JSON.parse(await file.text());
    if(!Array.isArray(data.events)||!Array.isArray(data.labels)||data.events.length>10000||!data.labels.every(l=>typeof l==='string'&&l.length<=30))throw new Error('备份格式无效');
    const incoming=data.events.map(validateEvent);const events=[...state.events];
    const signature=e=>JSON.stringify([e.title,e.targetDate,e.label,e.emoji,e.repeatType,e.isLunar,e.lunarMonth,e.lunarDay,e.isLunarLeap,e.notes,e.attachments,e.reminderMinutes,e.isArchived,e.repeatEvery,e.repeatUnit]);
    const known=new Set(events.map(signature));
    for(const event of incoming){if(known.has(signature(event)))continue;known.add(signature(event));if(events.some(x=>x.id===event.id))event.id=crypto.randomUUID();events.push(event);}
    const added=events.length-state.events.length;
    if(persist({...state,events,labels:[...new Set([...state.labels,...data.labels])]})){render();toast(`已导入 ${added} 个日子`);}
  }catch(error){toast(`导入失败，${error.message}`);}finally{e.target.value='';}
};
$('#clear').onclick=()=>{if(confirm('清空所有日子和标签？建议先导出备份。')&&persist({events:[],labels:defaultLabels,notified:[]})){category='全部日子';render();toast('已清空');}};
function checkReminders(){
  const now=Date.now();let notified=[...(state.notified||[])];let changed=false;
  for(const event of state.events){
    if(event.isArchived||event.reminderMinutes<0)continue;
    const date=nextOccurrence(event);if(!date)continue;
    const due=date.getTime()-event.reminderMinutes*60000;const key=`${event.id}-${date.getTime()}-${event.reminderMinutes}`;
    if(due>now||now-due>86400000||notified.includes(key))continue;
    toast(`日子提醒 · ${event.title}`);
    playReminderMusic(event.title);
    if('Notification' in window&&Notification.permission==='granted'){try{new Notification('日缄 · 日子提醒',{body:event.title,tag:key});}catch{/* In-page reminder remains available. */}}
    notified.push(key);changed=true;
  }
  if(changed)persist({...state,notified:notified.slice(-1000)});
  $('#reminder-status').textContent='提醒需保持页面打开。';
}
window.addEventListener('storage',e=>{if(e.key===KEY&&e.newValue){try{const data=JSON.parse(e.newValue);state={...data,events:data.events.map(validateEvent)};render();}catch{toast('另一窗口的数据无法读取，请导出备份后检查。');}}});
let currentDay=new Date().toDateString();
setInterval(()=>{if(new Date().toDateString()!==currentDay){currentDay=new Date().toDateString();render();}checkReminders();},30000);
document.addEventListener('visibilitychange',()=>{if(!document.hidden){render();checkReminders();}});
initializeMusic(toast);
render();checkReminders();if(loadFailed)toast('本地数据读取失败，原存储尚在，请先检查备份。');
