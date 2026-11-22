import test from 'node:test';
import assert from 'node:assert/strict';
import {nextAlarm,validateAlarm,alarmRequests} from '../dist/alarm-schedule.js';
const make=fields=>validateAlarm({id:'test',title:'起床',hour:7,minute:30,weekdays:[1,2,3,4,5],enabled:true,onceAt:null,...fields});
test('weekly selects next weekday and skips elapsed minute/weekend',()=>{
 const friday=new Date(2026,10,20,7,30).getTime();const next=new Date(nextAlarm(make(),friday));assert.equal(next.getDay(),1);assert.equal(next.getHours(),7);assert.equal(next.getMinutes(),30);
});
test('once is absolute and never rolls an expired alarm into tomorrow',()=>{
 const alarm=make({weekdays:[],onceAt:10000});assert.equal(nextAlarm(alarm,9000),10000);assert.equal(nextAlarm(alarm,10000),null);assert.equal(nextAlarm({...alarm,enabled:false},9000),null);
});
test('Sunday zero is preserved and native receives weekly rule',()=>{
 const now=new Date(2026,10,21,8).getTime();const alarm=make({weekdays:[0,0]});assert.deepEqual(alarm.weekdays,[0]);const request=alarmRequests([alarm],now)[0];assert.deepEqual(request.weekdays,[0]);assert.equal(new Date(request.time).getDay(),0);assert.equal(request.key,'alarm-test');
});
test('reject malformed imported schedules',()=>{
 for(const change of [{hour:24},{minute:-1},{weekdays:[7]},{enabled:'true'},{weekdays:[],onceAt:null}])assert.throws(()=>make(change));
});
test('spring DST follows local wall clock, not a 24-hour interval',()=>{
 const old=process.env.TZ;process.env.TZ='America/New_York';try {const now=new Date(2026,2,7,7,30).getTime();const next=nextAlarm(make({weekdays:[0,1,2,3,4,5,6]}),now);assert.equal((next-now)/3600000,23);assert.equal(new Date(next).getHours(),7);}finally{if(old)process.env.TZ=old;else delete process.env.TZ;}
});
