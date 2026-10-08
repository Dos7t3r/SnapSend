(() => {
  let staged = null;
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const visible = node => node && node.getClientRects().length > 0;
  const editor = () => {
    const classic = document.querySelector('#prompt-textarea');
    if (visible(classic)) return classic;
    const candidates = [...document.querySelectorAll('[contenteditable="true"][role="textbox"], textarea')]
      .filter(e => visible(e) && e.closest('form') && /chatgpt/i.test([e.getAttribute('aria-label'), e.getAttribute('placeholder')].join(' ')));
    return candidates.length === 1 ? candidates[0] : null;
  };
  const form = () => editor()?.closest('form') || editor()?.closest('[data-type="unified-composer"]');
  const send = () => [...(form()?.querySelectorAll('button') || [])].find(b => visible(b) &&
    (b.dataset.testid === 'send-button' || /^(Send|Send prompt|Send message|发送提示|发送消息|发送|傳送)$/.test(b.getAttribute('aria-label') || '')));
  const stopped = () => [...(form()?.querySelectorAll('button') || [])].some(b => visible(b) &&
    (b.dataset.testid === 'stop-button' || /^(Stop|停止|Stop generating|停止生成|Stop streaming)$/.test(b.getAttribute('aria-label') || '')));
  const messages = () => {
    const classic = [...document.querySelectorAll('[data-message-author-role="user"]')];
    if (classic.length) return classic;
    // New project layout labels user turns with a screen-reader heading rather than author metadata.
    return [...document.querySelectorAll('h4, [role="heading"][aria-level="4"]')]
      .filter(e => /^(你说：|你說：|You said:)$/.test(e.textContent.trim()))
      .map(e => e.parentElement).filter(Boolean);
  };
  function ready(inspect = false) {
    const input = editor();
    if (!input) return {ok:false,error:'未识别到聊天输入框（支持旧版和项目新版布局）。请等页面加载完成；若输入框已经显示，请确认扩展已更新至 0.5.0'};
    if (!form()) return {ok:false,error:'已找到输入框，但没有识别到附件操作区，请更新扩展后重试'};
    if ((input.innerText || input.value || '').trim()) return {ok:false,error:'等待：输入框有你的草稿，请先发送或清空'};
    if (stopped()) return {ok:false,error:'等待：AI 正在回答'};
    if (staged) return {ok:false,error:'已有待核对附件，请先核对并刷新页面'};
    const scope = form();
    if ([...scope.querySelectorAll('button')].some(b => /remove|移除|删除附件/i.test(b.getAttribute('aria-label') || '')))
      return {ok:false,error:'等待：输入框已有附件，请先处理'};
    return {ok:true};
  }
  async function attach(job) {
    const check = ready(); if (!check.ok) return check;
    const input = editor(), scope = form();
    const oldImages = scope.querySelectorAll('img').length;
    const oldRemoves = [...scope.querySelectorAll('button')].filter(b => /remove|移除|删除附件/i.test(b.getAttribute('aria-label') || '')).length;
    const bytes = Uint8Array.from(atob(job.jpeg), c => c.charCodeAt(0));
    const file = new File([bytes], job.filename, {type:'image/jpeg'});
    const transfer = new DataTransfer(); transfer.items.add(file);
    staged = {id: job.id, url: location.href, oldImages, oldRemoves, filename: job.filename};
    input.focus();
    const compatible = e => !e.disabled && (!e.accept || /image|\.jpg|\.jpeg/i.test(e.accept));
    const fileInput = [...scope.querySelectorAll('input[type=file]')].find(compatible) ||
      [...document.querySelectorAll('input[type=file]')].find(e => !e.disabled && /image|\.jpg|\.jpeg/i.test(e.accept));
    if (fileInput) { fileInput.files = transfer.files; fileInput.dispatchEvent(new Event('change', {bubbles:true})); }
    else { input.dispatchEvent(new ClipboardEvent('paste', {bubbles:true, cancelable:true, clipboardData:transfer})); }
    let stableReady = 0;
    for (let i=0;i<120;i++) {
      await wait(500);
      if (location.href !== staged.url) throw new Error('聊天已切换，请在原聊天核对附件');
      const current = form(); if (!current) continue;
      const removes = [...current.querySelectorAll('button')].filter(b => /remove|移除|删除附件/i.test(b.getAttribute('aria-label') || '')).length;
      const evidence = current.textContent.includes(job.filename) || current.querySelectorAll('img').length > oldImages || removes > oldRemoves;
      if (/upload failed|failed to upload|上传失败|无法上传/i.test(current.textContent)) throw new Error('网页提示附件上传失败，请核对后重试');
      const loading = current.querySelector('[role=progressbar], [aria-busy=true], [data-testid*=upload-progress], .animate-spin');
      const button = send();
      stableReady = evidence && !loading && button && !button.disabled && button.getAttribute('aria-disabled') !== 'true' ? stableReady + 1 : 0;
      if (stableReady >= 3) return {ok:true};
    }
    throw new Error('60 秒内未确认附件就绪。请在聊天核对；SnapSend 已暂停，不会重复发送');
  }
  async function submit(id) {
    if (!staged || staged.id !== id || staged.url !== location.href) throw new Error('附件与绑定聊天不匹配，请核对');
    const input = editor();
    if ((input?.innerText || input?.value || '').trim()) throw new Error('发送前出现文字草稿，已暂停');
    const button = send();
    if (!button || button.disabled || stopped()) throw new Error('发送按钮不可用，请核对附件');
    const baseline = new Set(messages());
    const previousLast = messages().at(-1);
    button.click();
    for (let i=0;i<40;i++) {
      await wait(500);
      if (location.href !== staged.url) throw new Error('发送后聊天发生变化，请核对');
      const users = messages();
      const last = users.at(-1);
      const scope = form();
      const cleared = scope && scope.querySelectorAll('img').length <= staged.oldImages &&
        [...scope.querySelectorAll('button')].filter(b => /remove|移除|删除附件/i.test(b.getAttribute('aria-label') || '')).length <= staged.oldRemoves;
      if (last && last !== previousLast && !baseline.has(last) && last.querySelector('img') && cleared) {
        staged = null; return {ok:true};
      }
    }
    throw new Error('已点击发送，但未确认新图片消息。请在 Mac 标记收到或重新排队');
  }
  async function sendPrompt(text, url) {
    const check = ready(); if (!check.ok) return check;
    if (typeof text !== 'string' || !text.trim() || text.length > 20000) throw new Error('提示词为空或过长，请在 Mac 设置中调整');
    const boundURL = url || location.href;
    if (location.href !== boundURL) throw new Error('聊天已切换，请重新绑定');
    const input = editor();
    input.focus();
    if (input.tagName === 'TEXTAREA') {
      const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
      setter.call(input, text);
      input.dispatchEvent(new Event('input', {bubbles:true}));
    } else if (!document.execCommand('insertText', false, text)) {
      throw new Error('无法填写提示词，请在聊天检查草稿');
    }
    const baseline = new Set(messages());
    const previousLast = messages().at(-1);
    const normalize = value => value.replace(/\s+/g, ' ').trim();
    for (let i = 0; i < 20; i++) {
      await wait(150);
      if (location.href !== boundURL) throw new Error('聊天已切换，请核对提示词草稿');
      if (normalize(input.innerText || input.value || '') !== normalize(text)) throw new Error('提示词草稿发生变化，已暂停发送');
      const button = send();
      if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true' || stopped()) continue;
      button.click();
      for (let j = 0; j < 40; j++) {
        await wait(500);
        if (location.href !== boundURL) throw new Error('发送后聊天已切换，请核对');
        const last = messages().at(-1);
        const cleared = !(editor()?.innerText || editor()?.value || '').trim();
        if (last && last !== previousLast && !baseline.has(last) && cleared &&
            normalize(last.textContent || '').includes(normalize(text))) return {ok:true};
      }
      throw new Error('已点击发送，但未确认提示词新消息，请在聊天核对');
    }
    throw new Error('发送按钮不可用，请在聊天核对提示词草稿');
  }
  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id) return;
    if (message.kind === 'ready') { respond(ready(message.inspect === true)); return; }
    const action = message.kind === 'attach' ? attach(message.job) :
                   message.kind === 'submit' ? submit(message.id) :
                   message.kind === 'sendPrompt' ? sendPrompt(message.text, message.url) : null;
    if (!action) return;
    action.then(respond).catch(error => respond({ok:false,error:error.message})); return true;
  });
})();
