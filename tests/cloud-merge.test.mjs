import test from 'node:test';import assert from 'node:assert/strict';
import {mergeCloudSnapshots,sameCloudValue} from '../dist/cloud-merge.js';
const state=events=>({events,labels:['工作'],alarms:[]});const item={id:'a',title:'原名',notes:'原备注'};
test('first migration merges both devices and preserves remote-only entries',()=>{const merged=mergeCloudSnapshots(state([]),state([item]),state([{id:'b',title:'手机日子'}]));assert.deepEqual(new Set(merged.events.map(e=>e.id)),new Set(['a','b']));});
test('concurrent independent edits merge per field',()=>{const merged=mergeCloudSnapshots(state([item]),state([{...item,title:'Mac标题'}]),state([{...item,notes:'手机备注'}]));assert.equal(merged.events[0].title,'Mac标题');assert.equal(merged.events[0].notes,'手机备注');});
test('remote deletion wins over stale offline edit',()=>{assert.equal(mergeCloudSnapshots(state([item]),state([{...item,title:'旧设备修改'}]),state([])).events.length,0);});
test('local deletion survives remote edits',()=>{assert.equal(mergeCloudSnapshots(state([item]),state([]),state([{...item,notes:'其他设备修改'}])).events.length,0);});
test('alarms and labels merge independently; device-local fields excluded',()=>{const merged=mergeCloudSnapshots(state([]),{...state([]),alarms:[{id:'alarm',hour:7}],labels:['工作','生日'],notified:['local']},{...state([]),labels:['工作','旅行']});assert.equal(merged.alarms[0].id,'alarm');assert.deepEqual(new Set(merged.labels),new Set(['工作','生日','旅行']));assert.equal(merged.notified,undefined);});
test('canonical equality prevents echo commits',()=>{assert.ok(sameCloudValue({b:1,a:2},{a:2,b:1}));});
