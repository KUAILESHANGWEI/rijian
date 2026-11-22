export function validateAlarm(value) {
  if (!value || typeof value.id !== 'string' || !value.id || value.id.length>100 || typeof value.title!=='string' || value.title.length>60 || !Number.isInteger(value.hour) || value.hour<0 || value.hour>23 || !Number.isInteger(value.minute) || value.minute<0 || value.minute>59 || !Array.isArray(value.weekdays) || value.weekdays.some(day=>!Number.isInteger(day)||day<0||day>6) || typeof value.enabled!=='boolean') throw new Error('闹钟格式无效');
  if (!value.weekdays.length && !Number.isFinite(value.onceAt)) throw new Error('闹钟日期无效');
  return {id:value.id,title:value.title.trim()||'闹钟',hour:value.hour,minute:value.minute,weekdays:[...new Set(value.weekdays)].sort(),enabled:value.enabled,onceAt:value.onceAt ?? null};
}
export function nextAlarm(alarm, now=Date.now()) {
  if (!alarm.enabled) return null;
  if (!alarm.weekdays.length) return alarm.onceAt>now ? alarm.onceAt : null;
  for (let offset=0;offset<=7;offset++) {
    const date=new Date(now);date.setDate(date.getDate()+offset);date.setHours(alarm.hour,alarm.minute,0,0);
    if (date.getTime()>now && alarm.weekdays.includes(date.getDay())) return date.getTime();
  }
  return null;
}
export function alarmRequests(alarms, now=Date.now()) {
  return (alarms||[]).map(validateAlarm).map(alarm=>({alarm,time:nextAlarm(alarm,now)})).filter(item=>item.time).map(({alarm,time})=>({key:`alarm-${alarm.id}`,title:alarm.title,time,hour:alarm.hour,minute:alarm.minute,weekdays:alarm.weekdays}));
}
