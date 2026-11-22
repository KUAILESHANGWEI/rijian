import {validateAlarm,nextAlarm} from './alarm-schedule.js?v=20';
import {prepareMusic,playReminderMusic} from './music.js?v=20';
const $=s=>document.querySelector(s);
const names=['日','一','二','三','四','五','六'];
const escape=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function initializeAlarms(getState,persist,toast) {
  const button=document.createElement('button');button.id='alarms';button.innerHTML='<svg class="utility-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="13" r="8"/><path d="M12 9v4l3 2M5 3 2 6m17-3 3 3M6 20l-1 2m13-2 1 2"/></svg><span class="utility-label">闹钟</span>';
  $('.app-utilities').insertBefore(button,$('#manage-groups'));
  const dialog=document.createElement('dialog');dialog.id='alarm-dialog';dialog.innerHTML=`<div class="dialog-heading"><h2>闹钟功能</h2><button class="close" aria-label="关闭">×</button></div><div id="alarm-list"></div><button id="alarm-new" class="primary">＋ 添加闹钟</button><form id="alarm-form" hidden><h3 id="alarm-edit-title">添加闹钟</h3><input name="id" type="hidden"><label>名称<input name="title" maxlength="60" placeholder="例如：起床、吃药" value="闹钟"></label><label>响铃时间<input name="time" type="time" required value="07:00"></label><label>重复<select id="alarm-repeat"><option value="once">仅一次</option><option value="daily">每天</option><option value="work">工作日</option><option value="custom">自选星期</option></select></label><fieldset id="alarm-weekdays" hidden><legend>选择重复星期</legend>${[1,2,3,4,5,6,0].map(day=>`<label><input type="checkbox" value="${day}">周${names[day]}</label>`).join('')}</fieldset><p id="alarm-error" class="error" role="alert"></p><div class="form-actions"><button type="button" id="alarm-cancel">取消</button><button class="primary" type="submit">保存闹钟</button></div></form><p class="group-hint">到时播放提醒音乐，整首结束后循环，点击“停止播放”结束。</p>`;
  document.body.append(dialog);
  dialog.querySelector('.close').onclick=()=>dialog.close();
  const form=$('#alarm-form');let busy=false;
  function render() {
    $('#alarm-list').innerHTML=(getState().alarms||[]).map(alarm=>{
      const next=nextAlarm(alarm);const repeat=alarm.weekdays.length===7?'每天':alarm.weekdays.length?alarm.weekdays.map(day=>'周'+names[day]).join('、'):'仅一次';
      return `<div class="alarm-row"><button class="alarm-edit" data-edit="${escape(alarm.id)}" aria-label="编辑${escape(alarm.title)}"><strong>${String(alarm.hour).padStart(2,'0')}:${String(alarm.minute).padStart(2,'0')}</strong><span>${escape(alarm.title)} · ${repeat}</span><small>${next?'下次 '+new Date(next).toLocaleString('zh-CN',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'}):'已关闭'}</small></button><label class="alarm-switch"><input type="checkbox" data-toggle="${escape(alarm.id)}" ${alarm.enabled?'checked':''} aria-label="${escape(alarm.title)}开关"></label><button data-remove="${escape(alarm.id)}" class="danger" aria-label="删除${escape(alarm.title)}">删除</button></div>`;
    }).join('')||'<p class="group-hint">还没有闹钟，添加一个想准时开始的时刻。</p>';
  }
  function save(alarms) {if(!persist({...getState(),alarms}))return false;render();return true;}
  function edit(alarm) {
    form.reset();form.hidden=false;$('#alarm-error').textContent='';form.elements.id.value=alarm?.id||'';form.elements.title.value=alarm?.title||'闹钟';form.elements.time.value=alarm?`${String(alarm.hour).padStart(2,'0')}:${String(alarm.minute).padStart(2,'0')}`:'07:00';
    const days=alarm?.weekdays||[];$('#alarm-repeat').value=days.length===7?'daily':days.join(',')==='1,2,3,4,5'?'work':days.length?'custom':'once';
    $('#alarm-weekdays').hidden=$('#alarm-repeat').value!=='custom';$('#alarm-weekdays').querySelectorAll('input').forEach(input=>input.checked=days.includes(Number(input.value)));$('#alarm-edit-title').textContent=alarm?'编辑闹钟':'添加闹钟';$('#alarm-new').hidden=true;
  }
  function closeForm(){form.hidden=true;$('#alarm-new').hidden=false;}
  button.onclick=()=>{render();closeForm();dialog.showModal();};$('#alarm-new').onclick=()=>edit();$('#alarm-cancel').onclick=closeForm;
  $('#alarm-repeat').onchange=()=>$('#alarm-weekdays').hidden=$('#alarm-repeat').value!=='custom';
  $('#alarm-list').onclick=event=>{
    const editButton=event.target.closest('[data-edit]');if(editButton)edit((getState().alarms||[]).find(a=>a.id===editButton.dataset.edit));
    const remove=event.target.closest('[data-remove]');if(remove&&confirm('删除这个闹钟？'))save((getState().alarms||[]).filter(a=>a.id!==remove.dataset.remove));
  };
  $('#alarm-list').onchange=event=>{
    const id=event.target.dataset.toggle;if(!id)return;
    const alarms=(getState().alarms||[]).map(alarm=>{if(alarm.id!==id)return alarm;const next={...alarm,enabled:event.target.checked};if(next.enabled&&!next.weekdays.length){const date=new Date();date.setHours(next.hour,next.minute,0,0);if(date<=new Date())date.setDate(date.getDate()+1);next.onceAt=date.getTime();}return next;});
    if(save(alarms)&&event.target.checked)window.rijianRequestAlarmPermission?.();
  };
  form.onsubmit=async event=>{
    event.preventDefault();if(busy)return;
    try {
      const [hour,minute]=form.elements.time.value.split(':').map(Number);const mode=$('#alarm-repeat').value;
      const weekdays=mode==='daily'?[0,1,2,3,4,5,6]:mode==='work'?[1,2,3,4,5]:mode==='custom'?[...$('#alarm-weekdays').querySelectorAll('input:checked')].map(i=>Number(i.value)):[];
      if(mode==='custom'&&!weekdays.length)throw new Error('请至少选择一个星期');
      const date=new Date();date.setHours(hour,minute,0,0);if(date<=new Date())date.setDate(date.getDate()+1);
      const alarm=validateAlarm({id:form.elements.id.value||crypto.randomUUID(),title:form.elements.title.value,hour,minute,weekdays,onceAt:weekdays.length?null:date.getTime(),enabled:true});
      busy=true;form.querySelector('[type=submit]').disabled=true;
      window.rijianRequestAlarmPermission?.();if(!window.rijianNativePlayReminder)await prepareMusic();
      const previous=getState().alarms||[];const alarms=previous.some(a=>a.id===alarm.id)?previous.map(a=>a.id===alarm.id?alarm:a):[...previous,alarm];
      if(save(alarms)){closeForm();toast('闹钟已保存');}
    }catch(error){$('#alarm-error').textContent=error.message;}
    finally{busy=false;form.querySelector('[type=submit]').disabled=false;}
  };
  function tick() {
    const now=Date.now();let changed=false;const state=getState();const fired=[...(state.alarmFired||[])];
    const alarms=(state.alarms||[]).map(alarm=>{
      if(!alarm.enabled)return alarm;
      let due=alarm.onceAt;
      if(alarm.weekdays.length){const date=new Date(now);date.setHours(alarm.hour,alarm.minute,0,0);if(!alarm.weekdays.includes(date.getDay()))return alarm;due=date.getTime();}
      const key=`alarm-${alarm.id}-${due}`;
      if(due>now||fired.includes(key))return alarm;
      if(now-due<60000){toast(`闹钟 · ${alarm.title}`);playReminderMusic(alarm.title,{id:`alarm-${alarm.id}`});fired.push(key);changed=true;}
      if(!alarm.weekdays.length){changed=true;return {...alarm,enabled:false};}return alarm;
    });
    if(changed){persist({...getState(),alarms,alarmFired:fired.slice(-1000)});render();}
  }
  tick();setInterval(tick,1000);document.addEventListener('visibilitychange',()=>{if(!document.hidden){tick();render();}});window.addEventListener('storage',()=>render());window.addEventListener('rijian-data-change',render);
}
