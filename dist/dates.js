import { Lunar, Solar, LunarMonth } from './vendor/lunar.js?v=12';
const DAY = 86400000;
export function dateInput(date) {
  const d = new Date(date);
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
export function dayDifference(date, now = new Date()) {
  const d = new Date(date);
  return Math.round((Date.UTC(d.getFullYear(),d.getMonth(),d.getDate()) - Date.UTC(now.getFullYear(),now.getMonth(),now.getDate())) / DAY);
}
function clampedDate(year, month, day, source) {
  const last = new Date(year,month+1,0).getDate();
  return new Date(year,month,Math.min(day,last),source.getHours(),source.getMinutes());
}
function customOccurrence(event, source, today) {
  const interval = event.repeatEvery || 1;
  const unit = event.repeatUnit || 'day';
  if (source >= today) return source;
  if (unit === 'day' || unit === 'week') {
    const days = interval * (unit === 'week' ? 7 : 1);
    const date = new Date(source);
    date.setDate(date.getDate()+Math.ceil(dayDifference(today,source)/days)*days);
    return date;
  }
  if (event.isLunar) {
    const lunar = Solar.fromDate(source).getLunar();
    const anchorMonth = LunarMonth.fromYm(lunar.getYear(),lunar.getMonth());
    for (let cycle = 0; cycle < 5000; cycle++) {
      const year = lunar.getYear()+cycle*interval;
      const month = unit === 'month' ? anchorMonth.next(cycle*interval) : LunarMonth.fromYm(year,lunar.getMonth());
      if (!month) continue;
      const solar = Lunar.fromYmd(month.getYear(),month.getMonth(),Math.min(event.lunarDay,month.getDayCount())).getSolar();
      const date = new Date(solar.getYear(),solar.getMonth()-1,solar.getDay(),source.getHours(),source.getMinutes());
      if (date >= today) return date;
    }
    return null;
  }
  const months = interval * (unit === 'year' ? 12 : 1);
  const elapsedMonths = (today.getFullYear()-source.getFullYear())*12+today.getMonth()-source.getMonth();
  let cycles = Math.max(0,Math.floor(elapsedMonths/months));
  let date = clampedDate(source.getFullYear(),source.getMonth()+cycles*months,source.getDate(),source);
  if (date < today) date = clampedDate(source.getFullYear(),source.getMonth()+(cycles+1)*months,source.getDate(),source);
  return date;
}
const lunarCache = new Map();
export function nextOccurrence(event, now = new Date()) {
  let source = new Date(event.targetDate);
  const today = new Date(now.getFullYear(),now.getMonth(),now.getDate());
  if (event.isLunar && ['从不','每周','每月','自定义'].includes(event.repeatType)) {
    const year = Solar.fromDate(source).getLunar().getYear();
    try {
      const solar = Lunar.fromYmd(year,event.isLunarLeap?-event.lunarMonth:event.lunarMonth,event.lunarDay).getSolar();
      source = new Date(solar.getYear(),solar.getMonth()-1,solar.getDay(),source.getHours(),source.getMinutes());
    } catch { return null; }
  }
  if (event.repeatType === '自定义') return customOccurrence(event,source,today);
  if (event.isLunar && event.repeatType === '每月') {
    const cursor = new Date(Math.max(today.getTime(),source.getTime()));
    for (let day = 0; day < 400; day++) {
      if (Solar.fromDate(cursor).getLunar().getDay() === event.lunarDay) {
        cursor.setHours(source.getHours(),source.getMinutes(),0,0);
        return cursor;
      }
      cursor.setDate(cursor.getDate()+1);
    }
    return null;
  }
  if (event.isLunar && event.repeatType === '每年') {
    const key = `${event.lunarMonth}-${event.lunarDay}-${event.isLunarLeap}-${dateInput(today)}`;
    let result = lunarCache.get(key);
    if (result === undefined) {
      result = null;
      for (let year = today.getFullYear()-1; year <= today.getFullYear()+24; year++) {
        try {
          const lunar = Lunar.fromYmd(year,event.isLunarLeap?-event.lunarMonth:event.lunarMonth,event.lunarDay);
          const solar = lunar.getSolar();
          const date = new Date(solar.getYear(),solar.getMonth()-1,solar.getDay());
          if (date >= today && (result === null || date.getTime() < result)) result = date.getTime();
        } catch {
          // A leap month or thirtieth lunar day may be absent in this year.
        }
      }
      lunarCache.set(key,result);
    }
    if (result === null) return null;
    const date = new Date(result);
    date.setHours(source.getHours(),source.getMinutes(),0,0);
    return date;
  }
  if (event.repeatType === '从不' || source >= today) return source;
  if (event.repeatType === '每周') {
    const date = new Date(source);
    date.setDate(date.getDate()+Math.ceil(dayDifference(today,source)/7)*7);
    return date;
  }
  if (event.repeatType === '每月') {
    let result = clampedDate(now.getFullYear(),now.getMonth(),source.getDate(),source);
    if (result < today) result = clampedDate(now.getFullYear(),now.getMonth()+1,source.getDate(),source);
    return result;
  }
  let result = clampedDate(now.getFullYear(),source.getMonth(),source.getDate(),source);
  if (result < today) result = clampedDate(now.getFullYear()+1,source.getMonth(),source.getDate(),source);
  return result;
}
export function validateEvent(raw) {
  if (!raw || typeof raw.title !== 'string' || !raw.title.trim() || raw.title.length > 100) throw new Error('日子名称无效');
  const targetDate = Number(raw.targetDate);
  const date = new Date(targetDate);
  if (!Number.isFinite(targetDate) || Number.isNaN(date.getTime()) || date.getFullYear()<1900 || date.getFullYear()>2100) throw new Error('日期须在 1900 至 2100 年之间');
  const repeatType = raw.repeatType || '从不';
  if (!['从不','每周','每月','每年','自定义'].includes(repeatType)) throw new Error('重复类型无效');
  const repeatEvery = Number(raw.repeatEvery ?? 1);
  const repeatUnit = raw.repeatUnit || 'day';
  if (!Number.isInteger(repeatEvery) || repeatEvery < 1 || repeatEvery > 999 || !['day','week','month','year'].includes(repeatUnit)) throw new Error('自定义重复须为每隔 1 至 999 天、周、月或年');
  const lunarMonth = Number(raw.lunarMonth ?? 1);
  const lunarDay = Number(raw.lunarDay ?? 1);
  if (!Number.isInteger(lunarMonth) || lunarMonth<1 || lunarMonth>12 || !Number.isInteger(lunarDay) || lunarDay<1 || lunarDay>30) throw new Error('农历日期无效');
  const reminderMinutes = Number(raw.reminderMinutes ?? -1);
  if (!Number.isInteger(reminderMinutes) || reminderMinutes < -1 || reminderMinutes>525600) throw new Error('提醒提前量无效');
  return {id:typeof raw.id==='string'?raw.id:crypto.randomUUID(),title:raw.title.trim(),emoji:String(raw.emoji || '🌿').slice(0,12),targetDate,label:String(raw.label||'纪念日').slice(0,30),repeatEvery,repeatUnit,colorHex:String(raw.colorHex||'#dfe5d9'),repeatType,reminderMinutes,isArchived:raw.isArchived===true,isLunar:raw.isLunar===true,lunarMonth,lunarDay,isLunarLeap:raw.isLunarLeap===true,notes:String(raw.notes||'').slice(0,10000),attachments:raw.attachments??''};
}
