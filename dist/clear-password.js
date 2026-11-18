const KEY = 'rijian-clear-password-v1';
const $ = selector => document.querySelector(selector);
let mode;
let toast;
let clear;
let busy = false;
function readPassword() {
  return JSON.parse(localStorage.getItem(KEY));
}
async function passwordHash(password, salt) {
  const key = await crypto.subtle.importKey('raw',new TextEncoder().encode(password),'PBKDF2',false,['deriveBits']);
  const bits = await crypto.subtle.deriveBits({name:'PBKDF2',salt:new Uint8Array(salt),iterations:210000,hash:'SHA-256'},key,256);
  return Array.from(new Uint8Array(bits));
}
async function verify(password, record) {
  if (!record || !Array.isArray(record.salt) || !Array.isArray(record.hash)) throw new Error('密码设置无法读取');
  const hash = await passwordHash(password,record.salt);
  return hash.length===record.hash.length && hash.every((value,index)=>value===record.hash[index]);
}
function openDialog(action) {
  try {
    const configured = !!readPassword();
    mode = action==='clear' && configured ? 'clear' : configured ? 'change' : 'setup';
    $('#password-form').reset();
    $('#password-error').textContent='';
    $('#password-title').textContent={clear:'验证清空密码',setup:'设置清空密码',change:'修改清空密码'}[mode];
    $('#old-password-field').hidden=mode==='setup';
    $('#new-password-fields').hidden=mode==='clear';
    $('#old-password').required=mode!=='setup';
    $('#new-password').required=mode!=='clear';
    $('#confirm-password').required=mode!=='clear';
    $('#password-submit').textContent=mode==='clear'?'验证并清空':'保存密码';
    $('#password-description').textContent=mode==='clear'?'验证后将清空所有日子和分组，请先确认备份已保存。':'设置后，每次清空所有日子都需要验证密码。请妥善保存密码。';
    $('#password-dialog').showModal();
  } catch { toast('密码设置读取失败，请检查存储权限。'); }
}
export function initializeClearPassword(onClear, onMessage) {
  clear=onClear;
  toast=onMessage;
  $('#clear').onclick=()=>openDialog('clear');
  $('#password-settings').onclick=()=>openDialog('settings');
  $('#password-form').onsubmit=async event=>{
    event.preventDefault();
    if (busy) return;
    busy=true;
    $('#password-submit').disabled=true;
    $('#password-error').textContent='';
    try {
      const record=readPassword();
      if (mode!=='setup' && !await verify($('#old-password').value,record)) throw new Error('密码不正确，请重新输入');
      if (mode==='clear') {
        if (clear()) { $('#password-dialog').close(); toast('已清空所有日子'); }
        return;
      }
      const password=$('#new-password').value;
      if (password.length<4 || password.length>128) throw new Error('密码长度须为 4 至 128 个字符');
      if (password!==$('#confirm-password').value) throw new Error('两次输入的密码不一致');
      if (mode==='setup' && record) throw new Error('密码已在其他窗口设置，请关闭后重试');
      const salt=Array.from(crypto.getRandomValues(new Uint8Array(16)));
      const hash=await passwordHash(password,salt);
      localStorage.setItem(KEY,JSON.stringify({salt,hash}));
      $('#password-dialog').close();
      toast('清空密码已保存');
    } catch (error) { $('#password-error').textContent=error.message || '操作失败，请重试'; }
    finally { busy=false; $('#password-submit').disabled=false; }
  };
  $('#password-dialog').addEventListener('close',()=>$('#password-form').reset());
}
