const byID = id=>document.getElementById(id);
let action='check', inflight=false;
const labels={focus:'打开已保存的聊天',bind:'绑定当前 Section 与聊天',enable:'开启自动发送',pause:'暂停自动发送',refresh:'刷新当前聊天页面',check:'重新检查连接'};
function render(view) {
  action=view.action || 'check';byID('hero').className='hero '+view.state;
  byID('state').textContent=({ready:'准备完成',error:'需要处理',working:'投递中',waiting:'等待中',setup:'下一步'})[view.state] || '连接状态';
  byID('title').textContent=view.title;byID('next').textContent=view.next;
  byID('primary').textContent=labels[action];
  byID('checks').replaceChildren(...view.checks.map(check=>{
    const row=document.createElement('div');row.className='row'+(check.ok?' done':'');
    const mark=document.createElement('span');mark.className='mark';mark.textContent=check.ok?'✓':'○';
    const text=document.createElement('div'),label=document.createElement('b'),detail=document.createElement('small');
    label.textContent=check.label;detail.textContent=check.detail;text.append(label,detail);row.append(mark,text);return row;
  }));
}
function error(text){byID('feedback').hidden=false;byID('feedback').textContent=text;}
async function check(){
  if(inflight)return;inflight=true;
  try{const result=await chrome.runtime.sendMessage({kind:'status'});if(result.view)render(result.view);else error('请重新加载新版扩展。');}
  catch{error('扩展尚未启动，请在 chrome://extensions 重新加载 SnapSend。');}
  finally{inflight=false;}
}
byID('check').addEventListener('click',()=>{byID('feedback').hidden=true;check();});
byID('primary').addEventListener('click',async()=>{
  if(inflight)return;
  if(action==='check'){byID('feedback').hidden=true;await check();return;}
  if(action==='refresh'){const [tab]=await chrome.tabs.query({active:true,currentWindow:true});await chrome.tabs.reload(tab.id);window.close();return;}
  inflight=true;byID('primary').disabled=true;byID('feedback').hidden=true;
  try{const result=await chrome.runtime.sendMessage({kind:action});if(!result.ok)error(result.status);else if(result.view)render(result.view);}
  catch{error('操作没有完成，请重新检查连接。');}
  finally{inflight=false;byID('primary').disabled=false;}
});
check();setInterval(check,4000);
