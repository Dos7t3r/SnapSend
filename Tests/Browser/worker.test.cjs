const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
function setup(overrides = {}) {
  let listener, timer, elapsed = 0;
  const requests = [], sent = [];
  const tab = {id:7, url:'https://chatgpt.com/c/class', active:true, windowId:1};
  let windowUpdates = 0;
  let portListener;
  let autoState = overrides.auto !== undefined ? overrides.auto : true;
  let queueCount = overrides.queued !== undefined ? overrides.queued : 1;
  const chrome = {
    runtime: {id:'test', onMessage:{addListener:fn=>listener=fn}, connectNative:()=>({
      onMessage:{addListener:fn=>portListener=fn},onDisconnect:{addListener:()=>{}},disconnect:()=>{},
      postMessage:request=>{
        requests.push(request);
        if (request.kind === 'enable') autoState = true;
        if (request.kind === 'pause') autoState = false;
        queueMicrotask(()=>portListener(overrides.native?.(request) || (
          request.kind==='poll' ? {ok:true,id:'photo',jpeg:'AA==',filename:'photo.jpg'} :
          request.kind==='status' ? {ok:true,version:3,lesson:'高数',usb:true,matching:true,auto:autoState,queued:queueCount} :
          {ok:true,lesson:'高数'}
        )));
      }
    })},
    tabs: {query:async()=>[tab],get:async()=>tab,update:async(id,opt)=>{Object.assign(tab,opt);return tab;},sendMessage:async(id,message)=>{sent.push(message.kind);return overrides.content?.(message) || {ok:true};}},
    windows:{get:async()=>({focused:false}),update:async()=>{windowUpdates++;return {focused:true};}}
  };
  const context=vm.createContext({chrome,URL,Date:{now:()=>Date.now()+elapsed},setTimeout:(fn,ms)=>{if(ms!==12000){timer=fn;return null;}return setTimeout(fn,ms);},clearTimeout,console});
  vm.runInContext(fs.readFileSync('chrome-extension/worker.js','utf8'),context);
  const bind=()=>new Promise(resolve=>listener({kind:'bind'},{id:'test'},resolve));
  return {advance:ms=>{elapsed+=ms;},bind,tick:()=>timer(),requests,sent,tab,windowUpdates:()=>windowUpdates,message:m=>new Promise(resolve=>listener(m,{id:"test"},resolve))};
}
test('binding rejects other origins without touching native host', async()=>{
  const s=setup(); s.tab.url='https://example.org/c/class'; const r=await s.bind();
  assert.equal(r.ok,false); assert.equal(s.requests.length,0);
});
test('different tab URL cannot take queued photos', async()=>{
  const s=setup(); assert.equal((await s.bind()).ok,true);s.tab.url='https://chatgpt.com/c/other';await s.tick();
  assert.equal(s.requests.some(r=>r.kind==='poll'),false);
  assert.equal(s.requests.at(-1).kind,'pageState');assert.match(s.requests.at(-1).detail,/绑定/);
});
test('inactive tab takes queued photos in background without focus stealing', async()=>{
  const s=setup(); assert.equal((await s.bind()).ok,true);s.tab.active=false;await s.tick();
  assert.equal(s.windowUpdates(),0);
  assert.equal(s.requests.some(r=>r.kind==='poll'),true);
});
test('when auto-send is paused, tick does not poll native host', async()=>{
  const s=setup({auto:false}); await s.bind(); await s.tick();
  assert.equal(s.requests.some(r=>r.kind==='poll'), false);
});
test('when queued photo count is 0, tick does not poll native host', async()=>{
  const s=setup({queued:0}); await s.bind(); await s.tick();
  assert.equal(s.requests.some(r=>r.kind==='poll'), false);
});
test('tick never calls chrome.windows.update or steals OS focus', async()=>{
  const s=setup(); await s.bind(); await s.tick();
  assert.equal(s.windowUpdates(), 0);
});
test('Mac permission denial never clicks send and reports uncertain', async()=>{
  const s=setup({native:r=>r.kind==='submitting'?{ok:false,error:'paused'}:null});
  await s.bind(); await s.tick(); assert.equal(s.sent.includes('submit'),false);
  assert.equal(s.requests.at(-1).state,'uncertain');
});
test('confirmed browser receipt is reported after durable submitting', async()=>{
  const s=setup(); await s.bind(); await s.tick();
  assert.deepEqual(s.requests.filter(r=>!['status','pageState'].includes(r.kind)).map(r=>r.kind),['bind','poll','submitting','result']);
  assert.equal(s.requests.at(-1).state,'sent');
});
test('failed attachment never clicks send', async()=>{
  const s=setup({content:m=>m.kind==='attach'?{ok:false,error:'upload timeout'}:null});
  await s.bind(); await s.tick();assert.equal(s.sent.includes('submit'),false);
  assert.equal(s.requests.at(-1).state,'uncertain');
});

test('binding uses inspection mode while popup is focused',async()=>{
  const s=setup({content:m=>m.kind==='ready' && !m.inspect?{ok:false,error:'not focused'}:null});
  assert.equal((await s.bind()).ok,true);
});
test('popup shows explicit next step after successful binding',async()=>{
  const s=setup({auto:false});await s.bind();const r=await s.message({kind:'status'});
  assert.equal(r.view.action,'enable');assert.equal(r.view.title,'已绑定，尚未开启发送');
});
test('popup cannot enable a different tab',async()=>{
  const s=setup();await s.bind();s.tab.id=99;const r=await s.message({kind:'enable'});
  assert.equal(r.ok,false);assert.equal(s.requests.some(r=>r.kind==='enable'),false);
});

test('project conversation binds and can take a photo',async()=>{
  const s=setup();s.tab.url='https://chatgpt.com/g/g-p-example-sta256/c/6ac67d7c-1698-83ea-9d8f-d46c60b2ac0c';
  assert.equal((await s.bind()).ok,true);await s.tick();
  assert.equal(s.requests.find(r=>r.kind==='poll').url,s.tab.url);
});
test('project landing pages and incomplete conversation paths cannot bind',async()=>{
  for(const url of ['https://chatgpt.com/g/g-p-example-sta256','https://chatgpt.com/c/','https://chatgpt.com/foo/c/chat','https://chatgpt.com/c/chat/extra']){
    const s=setup();s.tab.url=url;assert.equal((await s.bind()).ok,false);assert.equal(s.requests.length,0);
  }
});

test('unsupported editor displays explicit page repair action instead of bind loop',async()=>{
  const s=setup({content:()=>({ok:false,error:'未识别到聊天输入框'})});
  const result=await s.message({kind:'status'});assert.equal(result.view.action,'refresh');assert.equal(result.view.state,'error');
});

test('worker polls and dispatches sendPrompt when pending prompt exists', async () => {
  const s = setup({
    native: r => r.kind === 'poll' ? { ok: true, kind: 'prompt', text: '自动发送提示词' } : null
  });
  await s.bind();
  await s.tick();
  assert.equal(s.sent.includes('sendPrompt'), true);
  assert.equal(s.requests.some(r => r.kind === 'promptResult'), true);
});


test('prompt-only queue dispatches and reports the matching success field', async()=>{
  const s=setup({queued:0,native:r=>r.kind==='status'?{ok:true,version:4,lesson:'高数',usb:true,matching:true,auto:true,queued:0,hasPrompt:true}:r.kind==='poll'?{ok:true,kind:'prompt',id:'prompt-id',text:'开课'}:null});
  await s.bind();await s.tick();assert.equal(s.sent.includes('sendPrompt'),true);
  const receipt=s.requests.find(r=>r.kind==='promptResult');assert.equal(receipt.success,true);assert.equal(receipt.id,'prompt-id');
});
test('failed prompt sends a prompt failure receipt, never a photo receipt', async()=>{
  const s=setup({native:r=>r.kind==='poll'?{ok:true,kind:'prompt',id:'prompt-id',text:'开课'}:null,content:m=>m.kind==='sendPrompt'?{ok:false,error:'no receipt'}:null});
  await s.bind();await s.tick();assert.equal(s.requests.at(-1).kind,'promptResult');assert.equal(s.requests.at(-1).success,false);
  assert.equal(s.requests.some(r=>r.kind==='result'),false);
});

test('idle binding backs off native requests instead of polling each timer tick', async()=>{
  const s=setup({queued:0});await s.bind();await s.tick();const count=s.requests.length;
  await s.tick();assert.equal(s.requests.length,count);
});
test('page readiness reason reaches Mac without taking a photo job',async()=>{
  const s=setup({content:m=>m.kind==='ready' && !m.inspect?{ok:false,error:'等待：输入框有草稿'}:null});
  await s.bind();await s.tick();assert.equal(s.requests.at(-1).kind,'pageState');assert.match(s.requests.at(-1).detail,/草稿/);
  assert.equal(s.requests.some(r=>r.kind==='poll'),false);
});
test('focus is restored only on an explicit Mac request',async()=>{
  const s=setup({queued:0,native:r=>r.kind==='status'?{ok:true,version:4,lesson:'数学',matching:true,auto:true,queued:0,focusRequested:true}:null});
  await s.bind();await s.tick();assert.equal(s.windowUpdates(),1);assert.equal(s.requests.some(r=>r.kind==='focusResult'),true);
});
test('popup recovers the Mac saved Section chat without asking to bind again', async()=>{
  let restored=false;
  const s=setup({auto:false,native:r=>{
    if(r.kind==='restore'){restored=true;return {ok:true};}
    if(r.kind==='status')return {ok:true,version:4,lesson:'STA256 · LEC0101',targetURL:'https://chatgpt.com/c/class',section:'section-a',usb:true,matching:restored,auto:false,queued:0};
  }});
  const result=await s.message({kind:'status'});
  assert.equal(result.view.action,'enable');
  assert.equal(s.requests.some(r=>r.kind==='restore' && r.section==='section-a'),true);
  assert.equal(s.windowUpdates(),0);
});
test('saved Section restoration focuses only after an explicit focus request', async()=>{
  let changed=false;
  const s=setup({auto:false,native:r=>r.kind==='status'?{ok:true,version:4,lesson:'STA256',targetURL:changed?'https://chatgpt.com/c/section-b':'',section:'section-b',matching:!changed,focusRequested:changed,auto:false,queued:0,usb:true}:null});
  await s.bind(); changed=true; s.tab.url='https://chatgpt.com/c/section-b';
  await s.tick();
  assert.equal(s.requests.some(r=>r.kind==='restore' && r.url==='https://chatgpt.com/c/section-b'),true);
  assert.equal(s.windowUpdates(),1);
  assert.equal(s.requests.some(r=>r.kind==='poll'),false);
});

test('generation wait backs off and resumes the same queued photo without refreshing',async()=>{
  let generating=true;
  const s=setup({content:m=>m.kind==='ready' && !m.inspect && generating ? {ok:false,reason:'generating',canStop:true,error:'AI 正在回答'} : null});
  await s.bind();await s.tick();assert.equal(s.requests.some(r=>r.kind==='poll'),false);
  generating=false;s.advance(16000);await s.tick();assert.equal(s.requests.some(r=>r.kind==='poll'),true);
});
test('popup offers explicit stop and checks exact binding before acting',async()=>{
  let bound=false;
  const s=setup({content:m=>m.kind==='ready' && bound ? {ok:false,reason:'generating',canStop:true,error:'AI 正在回答'} : null});
  await s.bind();bound=true;
  assert.equal((await s.message({kind:'status'})).view.action,'stopGeneration');
  assert.equal((await s.message({kind:'stopGeneration'})).ok,true);assert.equal(s.sent.includes('stopGeneration'),true);
  s.tab.url='https://chatgpt.com/c/other';
  const count=s.sent.filter(x=>x==='stopGeneration').length;
  assert.equal((await s.message({kind:'stopGeneration'})).ok,false);assert.equal(s.sent.filter(x=>x==='stopGeneration').length,count);
});
test('readiness cannot release staged attachment until Mac resolves uncertainty and active send ends',async()=>{
  let review=true;
  const s=setup({native:r=>r.kind==='status'?{ok:true,version:5,lesson:'Math',usb:true,matching:true,auto:true,queued:1,review,inflight:false}:null,content:m=>{
    if(m.kind==='ready' && m.inspect && !review) assert.equal(m.releaseStaged,true);
    return {ok:true};
  }});
  await s.bind();assert.equal((await s.message({kind:'status'})).view.action,'check');
  review=false;await s.message({kind:'status'});
});

test('manual selected-photo dispatch does not masquerade as continuous auto-send',async()=>{
  const s=setup({native:r=>r.kind==='status'?{ok:true,version:5,lesson:'Math',matching:true,usb:true,auto:true,continuous:false,queued:1}:null});
  await s.bind();const v=(await s.message({kind:'status'})).view;
  assert.equal(v.title,'仅发送手动选中的图片');assert.equal(v.checks.find(c=>c.label==='自动发送').ok,false);
});

test('draft raced after lease requeues without uncertainty and resumes next check',async()=>{
 let deferred=true;
 const s=setup({native:r=>r.kind==='status'?{ok:true,version:6,auto:true,matching:true,queued:1}:null,content:m=>m.kind==='attach'&&deferred?{ok:false,deferred:true,error:'等待：有草稿'}:{ok:true}});
 await s.bind();await s.tick();
 assert.equal(s.requests.some(r=>r.kind==='defer'),true);
 assert.equal(s.requests.some(r=>r.kind==='result'&&r.state==='uncertain'),false);
 assert.equal(s.sent.includes('submit'),false);
 deferred=false;s.advance(7000);await s.tick();
 assert.equal(s.requests.some(r=>r.kind==='result'&&r.state==='sent'),true);
});

test('popup distinguishes resume of authorized pending tasks from enabling only new photos',async()=>{
  const s=setup({auto:false,native:r=>r.kind==='status'?{ok:true,version:6,lesson:'Math',usb:true,matching:true,auto:false,queued:0,pendingQueued:2}:null});
  await s.bind();
  assert.equal((await s.message({kind:'status'})).view.action,'resume');
  assert.equal((await s.message({kind:'resume'})).ok,true);
  assert.equal(s.requests.some(r=>r.kind==='resume'),true);
  s.tab.url='https://chatgpt.com/c/other';
  const count=s.requests.filter(r=>r.kind==='resume').length;
  assert.equal((await s.message({kind:'resume'})).ok,false);
  assert.equal(s.requests.filter(r=>r.kind==='resume').length,count);
  const old=setup({auto:false});await old.bind();
  assert.equal((await old.message({kind:'status'})).view.action,'enable');
});
