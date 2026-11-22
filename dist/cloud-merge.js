const same=(a,b)=>JSON.stringify(normalize(a))===JSON.stringify(normalize(b));
function normalize(value){if(Array.isArray(value))return value.map(normalize);if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(k=>[k,normalize(value[k])]));return value;}
export function cloudSnapshot(state){return {events:state.events||[],labels:state.labels||[],alarms:state.alarms||[]};}
export function mergeCloudSnapshots(base,local,remote){
 const result={};
 for(const kind of ['events','alarms','labels']){
  const key=value=>kind==='labels'?value:value.id;
  const old=new Map((base[kind]||[]).map(v=>[key(v),v]));const current=new Map((local[kind]||[]).map(v=>[key(v),v]));const server=new Map((remote[kind]||[]).map(v=>[key(v),v]));
  for(const id of new Set([...old.keys(),...current.keys()])){
   const before=old.get(id),edited=current.get(id);if(same(before,edited))continue;
   if(edited===undefined){server.delete(id);continue;}
   if(before!==undefined&&!server.has(id))continue;
   if(kind!=='labels'&&before&&server.has(id)){
    const merged={...server.get(id)};for(const field of new Set([...Object.keys(before),...Object.keys(edited)]))if(!same(before[field],edited[field])){if(edited[field]===undefined)delete merged[field];else merged[field]=edited[field];}server.set(id,merged);
   }else server.set(id,edited);
  }
  result[kind]=[...server.values()];
 }
 return result;
}
export {same as sameCloudValue};
