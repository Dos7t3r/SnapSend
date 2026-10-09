function isConversationURL(url) {
  return url.origin === 'https://chatgpt.com' && !url.username && !url.password &&
    /^\/(?:g\/[A-Za-z0-9_-]+\/)?c\/[A-Za-z0-9_-]+\/?$/.test(url.pathname);
}
let port;
let sequence = 0;
const pending = new Map();
let binding = null;
let busy = false;
let nextCheck = 0;
let wakeTimer;
let status = '请先绑定当前 ChatGPT 聊天';
function connect() {
  if (port) return;
  port = chrome.runtime.connectNative('com.snapsend.bridge');
  port.onMessage.addListener(message => {
    const request = pending.values().next().value;
    const key = pending.keys().next().value;
    if (request) { pending.delete(key); request.resolve(message); }
  });
  port.onDisconnect.addListener(() => {
    status = chrome.runtime.lastError?.message || '桥接断开，请打开 SnapSend 并安装浏览器桥接';
    port = null;
    for (const request of pending.values()) request.reject(new Error(status));
    pending.clear();
  });
}
// One outstanding request at a time so stdio responses are ordered.
let chain = Promise.resolve();
function native(message) {
  const run = () => new Promise((resolve, reject) => {
    connect();
    const id = ++sequence;
    const timer = setTimeout(() => {
      // Restart a stalled port; an old response must never satisfy the next request.
      port?.disconnect(); port = null;
      for (const request of pending.values()) request.reject(new Error('桥接响应超时，请重开 SnapSend'));
      pending.clear();
    }, 12000);
    pending.set(id, {resolve: value => {clearTimeout(timer); resolve(value);}, reject: error => {clearTimeout(timer); reject(error);}});
    try { port.postMessage(message); } catch (e) { pending.delete(id); clearTimeout(timer); reject(e); }
  });
  const result = chain.then(run, run); chain = result.catch(() => {}); return result;
}
// Only restore an exact URL supplied by the Mac's saved Section. Never infer another chat.
async function restoreTarget(mac, focus = false) {
  let url;
  try { url = new URL(mac.targetURL); } catch { return null; }
  if (!isConversationURL(url) || !mac.section) return null;
  const tabs = await chrome.tabs.query({url:'https://chatgpt.com/*'});
  let tab = tabs.find(t => t.url === mac.targetURL);
  if (!tab && focus) tab = await chrome.tabs.create({url:mac.targetURL,active:true});
  if (!tab) return null;
  const next = {tab:tab.id,url:mac.targetURL};
  const result = await native({kind:'restore',section:mac.section,...next});
  if (!result.ok) return null;
  binding = next; nextCheck = 0; scheduleTick(3000);
  if (focus) {
    await chrome.tabs.update(tab.id,{active:true});
    await chrome.windows.update(tab.windowId,{focused:true});
    await native({kind:'focusResult',...next});
  }
  return next;
}
async function tick() {
  if (busy || !binding || Date.now() < nextCheck) return;
  busy = true;
  let job;
  let interval = 3000;
  const bound = binding;
  try {
    let mac = await native({kind:'status',...bound});
    if (!mac.ok) throw new Error(mac.error);
    if (mac.targetURL && (!mac.matching || mac.focusRequested)) {
      const restored = await restoreTarget(mac, !!mac.focusRequested);
      if (restored) { interval = 3000; return; }
    }
    if (mac.focusRequested && !mac.targetURL) {
      const target = await chrome.tabs.get(bound.tab);
      if (target.url === bound.url) {
        await chrome.tabs.update(bound.tab, {active:true});
        await chrome.windows.update(target.windowId, {focused:true});
      }
      await native({kind:"focusResult", ...bound});
    }
    chrome.action?.setBadgeText({text:mac.review ? '!' : mac.auto ? (mac.continuous === false ? 'SEL' : 'ON') : 'OFF'});
    chrome.action?.setBadgeBackgroundColor({color:mac.review ? '#B42318' : mac.auto ? '#185A43' : '#B26A00'});

    // 1. 若未开启自动发送或有照片需核对，立即退出，绝对不执行任何操作
    if (!mac.auto || mac.review) {
      interval = 15000;
      status = mac.review ? '有照片需要核对' : '自动发送已暂停';
      return;
    }

    // 2. 若队列中无照片且无开课提示词待发，安静等待，不操作页面或标签页
    if (mac.queued === 0 && !mac.hasPrompt) {
      interval = mac.usb ? 3000 : 15000;
      status = '已就绪，等待新照片';
      return;
    }

    // 3. 有照片待发送或有提示词待发送：静默核验目标标签页
    let tab;
    try { tab = await chrome.tabs.get(bound.tab); } catch { interval = 15000; status = '绑定的聊天标签页已关闭，请重新绑定'; await native({kind:'pageState',detail:status,...bound}); return; }
    if (tab.url !== bound.url) { interval = 6000; status = '等待：请回到绑定的聊天标签页'; await native({kind:'pageState',detail:status,...bound}); return; }

    const readiness = await chrome.tabs.sendMessage(bound.tab, {kind: 'ready',releaseStaged:mac.inflight === false && !mac.review});
    if (!readiness.ok) { interval = readiness.reason === "generating" ? 15000 : 6000; status = readiness.error; await native({kind:"pageState", detail:status, ...bound}); return; }

    await native({kind:"pageState",detail:"",...bound});
    job = await native({kind: 'poll', ...bound});
    if (!job.ok) throw new Error(job.error);
    if (job.kind === 'prompt') {
      status = '正在发送课堂提示词...';
      const promptResult = await chrome.tabs.sendMessage(bound.tab, {kind: 'sendPrompt', text: job.text, url: bound.url});
      if (!promptResult.ok) throw new Error(promptResult.error);
      const saved = await native({kind: 'promptResult', id: job.id, success: true, ...bound});
      if (!saved.ok) throw new Error(saved.error);
      status = '开课提示词已发送给 AI';
      return;
    }
    if (!job.id) { status = job.message || '已连接，等待本课新照片'; return; }

    status = '正在后台上传课堂照片...';
    const result = await chrome.tabs.sendMessage(bound.tab, {kind: 'attach', job});
    if (!result.ok && result.deferred === true && mac.version >= 6) {
      const released = await native({kind:'defer',id:job.id,detail:result.error,...bound});
      if (!released.ok) throw new Error(released.error);
      status = result.error; interval = 6000; job = null; return;
    }
    if (!result.ok) throw new Error(result.error);

    const permission = await native({kind: 'submitting', id: job.id, ...bound});
    if (!permission.ok) throw new Error(permission.error);

    const receipt = await chrome.tabs.sendMessage(bound.tab, {kind: 'submit', id: job.id});
    const saved = await native({kind: 'result', id: job.id, state: receipt.ok ? 'sent' : 'uncertain', detail: receipt.ok ? '网页中已出现包含图片的新用户消息' : receipt.error, ...bound});
    if (!saved.ok) throw new Error(saved.error);
    status = receipt.ok ? '照片已发送，等待下一张' : receipt.error;
  } catch (error) {
    status = error.message || '投递失败，请在 Mac 核对';
    interval = 15000;
    if (port) { try { await native({kind:'pageState',detail:status,...bound}); } catch {} }
    if (job?.kind === 'prompt') {
      try { await native({kind: 'promptResult', id: job.id, success: false, error: status, ...bound}); } catch {}
    } else if (job?.id) { try { await native({kind: 'result', id: job.id, state: 'uncertain', detail: status, ...bound}); } catch {} }
  } finally { busy = false; nextCheck = Date.now() + interval; }
}
async function snapshot() {
  const view = {state:'setup',title:'正在检查连接',next:'',action:'check',checks:[],status,binding};
  const add = (label,ok,detail) => view.checks.push({label,ok,detail});
  const finish = () => {
    const color = view.state === 'error' ? '#B42318' : view.state === 'ready' ? '#185A43' : '#B26A00';
    chrome.action?.setBadgeText({text:view.state === 'ready' ? 'ON' : view.state === 'error' ? '!' : '…'});
    chrome.action?.setBadgeBackgroundColor({color});
    return view;
  };
  try {
    let mac = await native({kind:'status', ...(binding || {})});
    if (!mac.ok) throw new Error(mac.error);
    if (!mac.version || mac.version < 3) throw new Error('Mac 仍是旧版：请退出 SnapSend，再打开本次更新的版本');
    add('Mac 应用',true,'本机桥接已连接');
    add('当前 Section',!!mac.lesson,mac.lesson || '未选择，照片保存在收件箱');
    add('USB 手机',!!mac.usb,mac.usb ? '已连接' : '未连接，拍照前请连接');
    if (!mac.lesson) { view.title='选择一个 Section';view.next='Mac 已能保存照片。需要发送时，在 Mac 课程页选择 Section；未选择的照片进入收件箱。然后重新检查。';return finish(); }
    if (mac.targetURL && (!mac.matching || mac.focusRequested)) {
      const restored = await restoreTarget(mac, !!mac.focusRequested);
      if (restored) mac = await native({kind:'status',...restored});
    }
    const [tab] = await chrome.tabs.query({active:true,currentWindow:true});
    const url = new URL(tab?.url || 'about:blank');
    const valid = isConversationURL(url);
    add('当前网页',valid,valid ? (tab.title || 'ChatGPT 聊天') : '需要打开已有的 ChatGPT 聊天');
    if (!valid) { view.title='打开本课的 ChatGPT 聊天';view.next='先打开本课专用的具体聊天，支持普通聊天、项目和自定义 GPT 内的聊天。';return finish(); }
    let page;
    try { page = await chrome.tabs.sendMessage(tab.id,{kind:'ready',inspect:true,releaseStaged:mac.inflight === false && !mac.review}); }
    catch { view.state='error';view.title='聊天页面还未接入扩展';view.next='点击下方刷新当前页面，刷新完成后重新打开扩展。';view.action='refresh';return finish(); }
    if (!page.ok && /未识别|没有识别|找不到/.test(page.error || '')) {
      view.state='error';view.title='当前页面的输入框未识别';view.next=page.error;
      view.action='refresh';return finish();
    }
    const matched = !!binding && binding.tab === tab.id && binding.url === tab.url && mac.matching;
    add('聊天绑定',matched,matched ? '此标签页已绑定当前 Section' : '尚未绑定此 Section 与聊天');
    add('自动发送',(mac.continuous ?? mac.auto) === true,mac.continuous === false && mac.auto ? '已暂停 · 仅处理手动选中的图片' : mac.auto ? '已开启' : '已暂停');
    view.lesson=mac.lesson;view.queue=mac.queued;view.chat=tab.title || 'ChatGPT';view.url=tab.url;
    if (!matched && mac.targetURL && tab.url !== mac.targetURL) { view.title='打开已保存的 Section 聊天';view.next='当前网页是另一条聊天。打开已保存的目标，确认状态后再开启发送。';view.action='focus';return finish(); }
    if (!matched) { view.title='下一步：绑定此聊天';view.next='确认这是当前 Section 的专用聊天，点击绑定。绑定只保存目标；之后由你开启自动发送。';view.action='bind';return finish(); }
    if (mac.review) { view.state='error';view.title='有照片需要核对';view.next='在 Mac 选中待核对照片，到 ChatGPT 确认是否收到；核对后点击“重新检查连接”；输入框如有附件，请先手动处理。';view.action='check';return finish(); }
    if (!mac.auto) {
      const resume = mac.version >= 6 && (mac.pendingQueued ?? mac.queued) > 0;
      view.title=resume ? '已暂停，有待发送任务' : '已绑定，尚未开启发送';
      view.next=resume ? '恢复后会继续已授权的待发送任务，并发送新照片；仅保存和已取消的照片不会发送。' : '点击开启自动发送。仅处理之后的新照片，之前仅保存的图片不会自动发送。';
      view.action=resume ? 'resume' : 'enable';return finish();
    }
    if (busy) { view.state='working';view.title='正在投递照片';view.next='关闭此面板即可，聊天标签页保持打开。'+status;view.action='pause';return finish(); }
    if (!page.ok) { view.state='waiting';view.title='自动发送已开启，暂时等待';view.next=page.error;view.action=page.canStop ? 'stopGeneration' : 'check';return finish(); }
    view.state='ready';view.title=mac.continuous === false ? '仅发送手动选中的图片' : mac.usb ? '已就绪，可以拍照' : '发送已开启，请连接手机';
    view.next=mac.continuous === false ? '本次只发送选中的图片；其他照片只保存。完成后不会开启持续自动发送。' : mac.usb ? '聊天标签页保持打开即可；手机拍照确认后会在后台发送。' : '在 Mac 点击连接 iPhone；连接成功后，手机拍照确认即可。';
    view.action='pause';return finish();
  } catch(error) {
    view.state='error';view.title='Mac 桥接尚未连接';
    view.next=(error.message || '')+'。打开新版 Mac SnapSend；仍未连接时点击“安装浏览器桥接”，再重新检查。';
    return finish();
  }
}
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  // Popup only; content scripts cannot enqueue arbitrary native commands.
  if (sender.tab || sender.id !== chrome.runtime.id) return;
  if (message.kind === 'status') { snapshot().then(view=>respond({status:view.title,view})); return true; }
  if (message.kind === 'enable' || message.kind === 'resume' || message.kind === 'pause') {
    (async()=>{
      if (!binding) throw new Error('请先绑定聊天');
      const [tab] = await chrome.tabs.query({active:true,currentWindow:true});
      if (tab.id !== binding.tab || tab.url !== binding.url) throw new Error('当前标签页不是绑定的聊天，请重新绑定');
      const result = await native({kind:message.kind,...binding});
      if (!result.ok) throw new Error(result.error);
      respond({ok:true,view:await snapshot()});
    })().catch(error=>respond({ok:false,status:error.message}));
    return true;
  }
  if (message.kind === 'stopGeneration') {
    (async()=>{
      if (busy || !binding) throw new Error('正在投递或尚未绑定，暂不能停止回答');
      const [tab] = await chrome.tabs.query({active:true,currentWindow:true});
      if (tab.id !== binding.tab || tab.url !== binding.url) throw new Error('请回到绑定的聊天后操作');
      const mac = await native({kind:'status',...binding});
      if (!mac.ok || !mac.matching || mac.inflight || mac.review) throw new Error('请先处理当前投递和待核对照片');
      const result = await chrome.tabs.sendMessage(binding.tab,{kind:'stopGeneration',url:binding.url});
      if (!result.ok) throw new Error(result.error);
      nextCheck = 0; scheduleTick(3000);
      respond({ok:true,view:await snapshot()});
    })().catch(error=>respond({ok:false,status:error.message}));
    return true;
  }
  if (message.kind === 'focus') {
    (async () => {
      await native({kind:'requestFocus',...(binding || {})});
      const mac = await native({kind:'status',...(binding || {})});
      if (!await restoreTarget(mac,true)) throw new Error('无法恢复保存的聊天，请在 Mac 检查 Section 链接');
      respond({ok:true,view:await snapshot()});
    })().catch(error=>respond({ok:false,status:error.message}));
    return true;
  }
  if (message.kind === 'bind') {
    (async () => {
      if (busy) throw new Error('当前正在投递，请等照片完成后再绑定');
      const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
      const url = new URL(tab.url);
      if (!isConversationURL(url)) throw new Error('请先打开已有的 ChatGPT 聊天，支持项目内聊天；请打开具体对话而非项目首页');
      const ready = await chrome.tabs.sendMessage(tab.id, {kind: 'ready', inspect:true});
      if (!ready.ok) throw new Error(ready.error);
      const next = {tab: tab.id, url: tab.url};
      const result = await native({kind: 'bind', ...next});
      if (!result.ok) throw new Error(result.error);
      binding = next; nextCheck = 0; scheduleTick(3000); status = `已绑定 ${result.lesson}，请在 Mac 开启自动发送`;
      respond({ok: true, status, view:await snapshot()});
    })().catch(error => respond({ok: false, status: error.message}));
    return true;
  }
});
// connectNative keeps the MV3 worker alive. A popup can recover the saved Section URL after restart.
function scheduleTick(delay) {
  clearTimeout(wakeTimer);
  wakeTimer = setTimeout(async () => {
    await tick();
    if (binding) scheduleTick(Math.max(3000, nextCheck - Date.now()));
  }, delay);
}
