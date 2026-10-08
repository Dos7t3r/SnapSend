const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
function setup(options = {}) {
  let listener, images = 0, clicks = 0, users = options.olderOnly || options.virtualized ? [{querySelector:()=>({})}] : [];
  const input = {innerText:options.draft || '', getClientRects:()=>[{}],focus:()=>{},closest:()=>scope,getAttribute:()=> '询问 ChatGPT'};
  const button = {dataset:options.project?{}:{testid:'send-button'},disabled:false,getAttribute:()=>options.project?'发送':null,getClientRects:()=>[{}],click:()=>{clicks++; if(options.olderOnly) {users.unshift({querySelector:()=>({})});images=0;} else if(options.confirm !== false) { if(options.virtualized) users=[];users.push({querySelector:()=>({}),textContent:input.innerText}); input.innerText=''; images=0; }}};
  const scope = {textContent:'',querySelector:()=>null,querySelectorAll:key=>key==='button'?[button,...(options.generating?[{dataset:{},getClientRects:()=>[{}],getAttribute:()=> '停止'}]:[])]:key==='img'?Array(images).fill({}):key==='input[type=file]' && options.composerFile?[file]:[]};
  const file = {disabled:false,accept:'image/jpeg',dispatchEvent:()=>{if(options.upload !== false)images++;}};
  const document = {
    execCommand: (command, ui, text) => {input.innerText=text;return true;},
    visibilityState: options.hidden ? 'hidden' : 'visible', hasFocus:()=>options.focus !== false, querySelector:key=>key==='#prompt-textarea' && !options.project?input:null,
    querySelectorAll:key=>key==='button'?[button,...(options.generating?[{dataset:{testid:'stop-button'},getClientRects:()=>[{}],getAttribute:()=>null}]:[])]:key==='input[type=file]'?(options.composerFile?[{disabled:false,accept:'image/*',dispatchEvent:()=>{throw Error('wrong file input')}}]:[file]):key.includes('data-message-author-role')?(options.project?[]:users):key.startsWith('[contenteditable')?(options.project?[input]:[]):key.startsWith('h4')?(options.project?users.map(parent=>({textContent:'你说：',parentElement:parent})):[]):[]
  };
  const context = vm.createContext({document,location:{href:'https://chatgpt.com/c/class'},chrome:{runtime:{id:'test',onMessage:{addListener:fn=>listener=fn}}},
    setTimeout:fn=>queueMicrotask(fn),Uint8Array,atob,File:class {},Event:class {},DataTransfer:class {constructor(){this.files=[];this.items={add:x=>this.files.push(x)};}},ClipboardEvent:class {}});
  vm.runInContext(fs.readFileSync('chrome-extension/content.js','utf8'),context);
  const message = m => new Promise(resolve=>listener(m,{id:'test'},resolve));
  return {message,clicks:()=>clicks};
}
const job = {id:'photo',jpeg:'AA==',filename:'photo.jpg'};
test('user draft blocks attachment',async()=>{const s=setup({draft:'notes'});assert.equal((await s.message({kind:'ready'})).ok,false);assert.equal(s.clicks(),0);});
test('AI generation blocks attachment',async()=>{const s=setup({generating:true});assert.equal((await s.message({kind:'ready'})).ok,false);});
test('attachment upload timeout never sends',async()=>{const s=setup({upload:false});assert.equal((await s.message({kind:'attach',job})).ok,false);assert.equal(s.clicks(),0);});
test('new image user message confirms submission',async()=>{const s=setup();assert.equal((await s.message({kind:'attach',job})).ok,true);assert.equal(s.clicks(),0);assert.equal((await s.message({kind:'submit',id:'photo'})).ok,true);assert.equal(s.clicks(),1);});
test('click without receipt is uncertain, not success',async()=>{const s=setup({confirm:false});await s.message({kind:'attach',job});assert.equal((await s.message({kind:'submit',id:'photo'})).ok,false);assert.equal(s.clicks(),1);});

test('unfocused or background window allows attachment without manual focus click',async()=>{const s=setup({focus:false});assert.equal((await s.message({kind:'ready'})).ok,true);assert.equal((await s.message({kind:'attach',job})).ok,true);});
test('hidden or background tab allows background attachment without blocking',async()=>{const s=setup({hidden:true});assert.equal((await s.message({kind:'ready'})).ok,true);assert.equal((await s.message({kind:'attach',job})).ok,true);});

test('upload uses current composer before unrelated image inputs',async()=>{const s=setup({composerFile:true});assert.equal((await s.message({kind:'attach',job})).ok,true);});

test('new project layout has no prompt-textarea ID but binds and confirms image',async()=>{
  const s=setup({project:true,composerFile:true});
  assert.equal((await s.message({kind:'ready',inspect:true})).ok,true);
  assert.equal((await s.message({kind:'attach',job})).ok,true);
  assert.equal((await s.message({kind:'submit',id:'photo'})).ok,true);assert.equal(s.clicks(),1);
});
test('new project stop button blocks sending',async()=>{
  const s=setup({project:true,generating:true});assert.equal((await s.message({kind:'ready',inspect:true})).ok,false);assert.equal(s.clicks(),0);
});

test('loading earlier history does not count as new image receipt',async()=>{
  const s=setup({project:true,olderOnly:true});await s.message({kind:'attach',job});assert.equal((await s.message({kind:'submit',id:'photo'})).ok,false);
});
test('virtualized project conversation can confirm new last user image',async()=>{
  const s=setup({project:true,virtualized:true});await s.message({kind:'attach',job});assert.equal((await s.message({kind:'submit',id:'photo'})).ok,true);
});

test('sendPrompt inputs text and clicks send button', async () => {
  const s = setup();
  assert.equal((await s.message({kind: 'sendPrompt', text: '开课提示词'})).ok, true);
  assert.equal(s.clicks(), 1);
});


test('prompt preserves user draft instead of overwriting it', async()=>{
  const s=setup({draft:'my notes'});assert.equal((await s.message({kind:'sendPrompt',text:'prompt'})).ok,false);assert.equal(s.clicks(),0);
});
test('prompt click without new text receipt reports uncertainty', async()=>{
  const s=setup({confirm:false});assert.equal((await s.message({kind:'sendPrompt',text:'prompt'})).ok,false);assert.equal(s.clicks(),1);
});
test('prompt cannot send into a different conversation', async()=>{
  const s=setup();assert.equal((await s.message({kind:'sendPrompt',text:'prompt',url:'https://chatgpt.com/c/other'})).ok,false);assert.equal(s.clicks(),0);
});
