const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const tasksEl = $('#tasks');
const resultState = { single: [], batch: [] };
let currentFilter = 'all';
let taskVisibleLimit = 60;
let mediaVisibleLimit = 60;
let completedJobs = [];
let selectedMediaId = '';
const selectedMediaIds = new Set();
let librarySignature = '';
let sourcePreviewRequest = 0;
let mediaRefreshTick = 0;
let playerAudioContext = null;
let playerAudioGain = null;
let playerAudioSource = null;
let tasksLoading = false;
let taskJobs = [];
let taskSearch = '';
const selectedTaskIds = new Set();

function extractUrls(text) {
  return (text.match(/https?:\/\/[\s\S]*?(?=https?:\/\/|\s|$)/gi) || [])
    .map((url) => url.replace(/[，,；;。]+$/, '').trim())
    .filter(Boolean);
}

function escapeHtml(value = '') {
  return String(value).replace(/[&<>"']/g, (char) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' })[char]);
}

function formatBytes(bytes) {
  if (!bytes) return '';
  const units = ['B','KB','MB','GB'];
  let value = bytes; let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
  return `${value.toFixed(unit > 1 ? 1 : 0)} ${units[unit]}`;
}

function formatDuration(seconds) {
  if (!seconds) return '';
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h ? `${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}` : `${m}:${String(s).padStart(2,'0')}`;
}

function parseKeywords(value = '') {
  return [...new Set(String(value).split(/[\r\n,，、;；]+/).map((item) => item.trim()).filter(Boolean))].slice(0, 50);
}

function filterUrlsByKeywords(urls, keywords) {
  const normalized = keywords.map((keyword) => keyword.toLocaleLowerCase());
  const included = [];
  let skipped = 0;
  for (const url of urls) {
    const candidate = url.toLocaleLowerCase();
    if (normalized.some((keyword) => candidate.includes(keyword))) skipped++;
    else included.push(url);
  }
  return { included, skipped };
}

function titleBaseName(title, pageUrl = '') {
  let value = String(title || '').replace(/\s+/g, ' ').trim();
  value = value.replace(/\.(?:mp4|m3u8)$/i, '').trim();
  // Page titles often end in a short site name separated by a dash or vertical bar.
  value = value.replace(/\s+(?:-|\||｜)\s*[^|｜-]{1,32}$/u, '').trim();
  value = value.replace(/[\x00-\x1F<>:"/\\|?*]/g, '_').replace(/[. ]+$/g, '').trim();
  if (!value) {
    value = pageUrl.match(/\/archives\/([^/.?#]+)/i)?.[1]
      || pageUrl.match(/\/video\/(BV[0-9A-Za-z]+)/i)?.[1]
      || 'video';
  }
  if (/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i.test(value)) value = `_${value}`;
  return value.slice(0, 80).replace(/[. ]+$/g, '').trim() || 'video';
}

async function api(path, options = {}) {
  const response = await fetch(path, options);
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `请求失败：${response.status}`);
  return data;
}

async function checkService() {
  const status = $('#service-status');
  try {
    await api('/health');
    status.classList.add('online');
    status.innerHTML = '<span></span>本地服务已连接';
  } catch {
    status.classList.remove('online');
    status.innerHTML = '<span></span>服务未连接';
  }
}

function modeElements(mode) {
  return {
    panel: $(`#${mode}-results-panel`),
    results: $(`#${mode}-results`),
    enqueue: $(`#enqueue-${mode}`),
    count: $(`#${mode}-selected-count`),
    selectAll: $(`#select-all-${mode}`)
  };
}

function updateSelectedCount(mode) {
  const ui = modeElements(mode);
  const selected = $$(`.stream-check[data-mode="${mode}"]:checked:not(:disabled)`).length;
  const available = $$(`.stream-check[data-mode="${mode}"]:not(:disabled)`).length;
  ui.count.textContent = `已选择 ${selected} 个视频流`;
  ui.enqueue.disabled = selected === 0;
  ui.selectAll.checked = available > 0 && selected === available;
  ui.selectAll.indeterminate = selected > 0 && selected < available;
  ui.selectAll.disabled = available === 0;
  $$('.result-group', ui.results).forEach((group) => {
    const checks = $$('.stream-check:not(:disabled)', group);
    const groupSelected = checks.filter((input) => input.checked).length;
    const groupCheck = $('.group-check', group);
    if (!groupCheck) return;
    groupCheck.disabled = checks.length === 0;
    groupCheck.checked = checks.length > 0 && groupSelected === checks.length;
    groupCheck.indeterminate = groupSelected > 0 && groupSelected < checks.length;
  });
}

function renderResults(mode, pages) {
  const ui = modeElements(mode);
  resultState[mode] = [];
  ui.results.replaceChildren();
  pages.forEach((page, pageIndex) => {
    const streams = (Array.isArray(page.streams) ? page.streams : [])
      .map((stream) => typeof stream === 'string' ? stream : stream?.url)
      .filter(Boolean);
    const group = document.createElement('div');
    group.className = 'result-group';
    group.dataset.groupId = `${mode}-group-${pageIndex}`;
    const title = page.error ? `解析失败：${page.error}` : `${streams.length} 个视频流`;
    const pageUrl = page.pageUrl || page.url || '';
    const label = page.title || pageUrl || '未命名文章';
    const baseName = titleBaseName(label, pageUrl);
    group.innerHTML = `<div class="result-group-title"><strong title="${escapeHtml(label)}">${escapeHtml(label)}</strong><div class="result-group-meta"><span>${escapeHtml(title)}</span><label class="group-select"><input class="group-check" data-group-id="${group.dataset.groupId}" type="checkbox" checked${streams.length ? '' : ' disabled'}>本链接全选</label></div></div>`;
    if (!page.error && !streams.length) {
      const empty = document.createElement('div');
      empty.className = 'result-group-empty';
      empty.textContent = '未发现视频流';
      group.appendChild(empty);
    }
    streams.forEach((stream, index) => {
      const id = `${mode}-stream-${resultState[mode].length}`;
      const item = { id, url:stream, referer:pageUrl, title:label, folder:baseName, filename:streams.length === 1 ? `${baseName}.mp4` : `${baseName}-${index + 1}.mp4` };
      resultState[mode].push(item);
      const row = document.createElement('label');
      row.className = 'stream-row';
      row.innerHTML = `<input class="stream-check" data-mode="${mode}" data-group-id="${group.dataset.groupId}" data-id="${id}" type="checkbox" checked><span class="stream-url" title="${escapeHtml(stream)}">${escapeHtml(stream)}</span><input class="stream-filename" data-mode="${mode}" data-id="${id}" value="${escapeHtml(item.filename)}" aria-label="文件名">`;
      group.appendChild(row);
    });
    $('.group-check', group)?.addEventListener('change', (event) => {
      $$('.stream-check:not(:disabled)', group).forEach((input) => { input.checked = event.target.checked; });
      updateSelectedCount(mode);
    });
    ui.results.appendChild(group);
  });
  ui.panel.classList.toggle('hidden', resultState[mode].length === 0 && !pages.some((page) => page.error));
  $$(`.stream-check[data-mode="${mode}"]`).forEach((input) => input.addEventListener('change', () => updateSelectedCount(mode)));
  updateSelectedCount(mode);
}

function normalizeCategoryResults(data) {
  const groups = [];
  for (const page of (Array.isArray(data?.pages) ? data.pages : [])) {
    if (Array.isArray(page.articles)) {
      if (page.error && page.articles.length === 0) groups.push({ title:`第 ${page.page || ''} 页分类扫描失败`, pageUrl:page.url || '', streams:[], error:page.error });
      for (const article of page.articles) groups.push({ title:article.title || article.url || article.pageUrl || '未命名文章', pageUrl:article.url || article.pageUrl || '', streams:Array.isArray(article.streams) ? article.streams : [], error:article.error });
    } else if (page.url || page.pageUrl || page.streams || page.error) {
      groups.push({ title:page.title || page.url || page.pageUrl, pageUrl:page.url || page.pageUrl || '', streams:Array.isArray(page.streams) ? page.streams : [], error:page.error });
    }
  }
  return groups;
}

async function analyze() {
  const button = $('#analyze');
  const message = $('#analyze-message');
  const urls = extractUrls($('#page-urls').value);
  const keywords = parseKeywords($('#single-exclude-keywords').value);
  const filtered = filterUrlsByKeywords(urls, keywords);
  if (!urls.length) { message.textContent = '请输入有效的网址'; message.className = 'message error'; return; }
  if (!filtered.included.length) {
    renderResults('single', []);
    message.textContent = `所有 ${urls.length} 个网址均命中排除关键词，未发起解析`;
    message.className = 'message';
    return;
  }
  button.disabled = true;
  message.textContent = `正在解析 ${filtered.included.length} 个网址${filtered.skipped ? `，已跳过 ${filtered.skipped} 个` : ''}…`;
  message.className = 'message';
  try {
    const data = await api('/analyze', { method:'POST', headers:{'Content-Type':'application/json; charset=utf-8'}, body:JSON.stringify({ urls: filtered.included, excludeKeywords: keywords }) });
    renderResults('single', data.pages || []);
    const count = (data.pages || []).reduce((sum, page) => sum + (Array.isArray(page.streams) ? page.streams.length : 0), 0);
    message.textContent = `解析完成，共发现 ${count} 个视频流${filtered.skipped ? `，按关键词跳过 ${filtered.skipped} 个网址` : ''}`;
  } catch (error) {
    message.textContent = error.message;
    message.className = 'message error';
  } finally { button.disabled = false; }
}

async function analyzeCategory() {
  const button = $('#category-analyze');
  const message = $('#category-message');
  const summary = $('#category-summary');
  const url = $('#category-url').value.trim();
  const range = $('#category-range').value.trim();
  const keywords = parseKeywords($('#category-exclude-keywords').value);
  if (!url) { message.textContent = '请输入分类页网址'; message.className = 'message error'; return; }
  if (!/^\d+(?:\s*-\s*\d+)?$/.test(range)) { message.textContent = '页码范围格式应为 1-8 或单个页码'; message.className = 'message error'; return; }
  button.disabled = true;
  message.className = 'message';
  message.textContent = `正在扫描分类页${keywords.length ? `，已启用 ${keywords.length} 个排除关键词` : ''}，请稍候…`;
  summary.textContent = '';
  try {
    const started = await api('/category-analyze', { method:'POST', headers:{'Content-Type':'application/json; charset=utf-8'}, body:JSON.stringify({ url, range, excludeKeywords: keywords }) });
    let data;
    if (started.taskId) {
      let state;
      do {
        await new Promise((resolve) => setTimeout(resolve, 1000));
        state = await api(`/category-status?id=${encodeURIComponent(started.taskId)}`);
        message.textContent = state.status === 'running' ? '正在后台扫描分类页…' : message.textContent;
      } while (state.status === 'running');
      if (state.status === 'error') throw new Error(state.error || '分类扫描失败');
      data = state.result || {};
    } else data = started;
    const groups = normalizeCategoryResults(data);
    renderResults('batch', groups);
    const articleCount = Number.isFinite(Number(data.articleCount)) ? Number(data.articleCount) : groups.length;
    const streamCount = Number.isFinite(Number(data.streamCount)) ? Number(data.streamCount) : groups.reduce((sum, group) => sum + group.streams.length, 0);
    const pageCount = Array.isArray(data.pages) ? data.pages.length : 0;
    const skippedCount = Number.isFinite(Number(data.skippedCount)) ? Number(data.skippedCount) : 0;
    message.textContent = `扫描完成，共发现 ${articleCount} 篇文章、${streamCount} 个视频流`;
    summary.textContent = pageCount ? `已扫描 ${pageCount} 个分类页` : '';
    if (skippedCount) summary.textContent += `${summary.textContent ? ' · ' : ''}已跳过 ${skippedCount} 个匹配链接`;
    if (Array.isArray(data.warnings) && data.warnings.length) summary.textContent += `${summary.textContent ? ' · ' : ''}${data.warnings.length} 条提示`;
  } catch (error) {
    message.textContent = error.message;
    message.className = 'message error';
  } finally { button.disabled = false; }
}

async function enqueueSelected(mode) {
  const ui = modeElements(mode);
  const selected = $$(`.stream-check[data-mode="${mode}"]:checked:not(:disabled)`);
  if (!selected.length) {
    ui.count.textContent = '请先选择至少一个视频流';
    ui.count.title = '';
    return;
  }
  ui.enqueue.disabled = true;
  ui.enqueue.textContent = '正在加入…';
  let added = 0;
  let skipped = 0;
  const failures = [];
  try {
    for (const checkbox of selected) {
      const item = resultState[mode].find((stream) => stream.id === checkbox.dataset.id);
      if (!item) {
        failures.push('找不到对应的视频流');
        continue;
      }
      const filenameInput = $(`.stream-filename[data-mode="${mode}"][data-id="${item.id}"]`);
      const filename = filenameInput?.value.trim() || item.filename;
      const payload = {
        url: String(item.url || ''),
        referer: String(item.referer || ''),
        title: String(item.title || ''),
        folder: String(item.folder || titleBaseName(item.title, item.referer)),
        filename: String(filename || item.filename || 'video.mp4')
      };
      try {
        const result = await api('/download', { method:'POST', headers:{'Content-Type':'application/json; charset=utf-8'}, body:JSON.stringify(payload) });
        checkbox.checked = false;
        checkbox.disabled = true;
        if (result.duplicate) skipped++;
        else added++;
      } catch (error) {
        const reason = error instanceof Error ? error.message : String(error);
        failures.push(`${payload.filename}：${reason}`);
        console.error('加入下载队列失败', { item, error });
      }
    }
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    failures.push(`加入流程异常：${reason}`);
    console.error('加入下载队列异常', error);
  }

  updateSelectedCount(mode);
  // Keep the button locked while the result message is visible; failed items can be retried after the count resets.
  ui.enqueue.disabled = true;
  const resultParts = [`已加入 ${added} 个`];
  if (skipped) resultParts.push(`跳过重复 ${skipped} 个`);
  if (failures.length) resultParts.push(`失败 ${failures.length} 个`);
  ui.enqueue.textContent = resultParts.join('，');
  ui.count.textContent = failures.length
    ? `${ui.count.textContent}；${failures[0]}`
    : resultParts.join('，');
  ui.count.title = failures.join('\n');
  setTimeout(() => {
    ui.enqueue.textContent = '加入下载队列';
    ui.count.title = '';
    updateSelectedCount(mode);
  }, 2600);
  await loadTasks();
}

function switchView(viewId) {
  $$('.workspace-tab').forEach((tab) => tab.classList.toggle('active', tab.dataset.view === viewId));
  $$('.workspace-view').forEach((view) => view.classList.toggle('active', view.id === viewId));
  if (viewId === 'preview-view') loadTasks(true);
}

const browserState = { history: [], index: -1, currentUrl: '' };
const browserHistoryKey = 'm3u8-downloader-browser-history-v1';

function browserLoadHistory() {
  try {
    const saved = JSON.parse(localStorage.getItem(browserHistoryKey) || '[]');
    browserState.history = Array.isArray(saved) ? saved.filter((url) => /^https?:\/\//i.test(url)).slice(0, 20) : [];
  } catch { browserState.history = []; }
  browserState.index = -1;
}

function browserSaveHistory() {
  try { localStorage.setItem(browserHistoryKey, JSON.stringify(browserState.history)); } catch { /* Storage may be disabled in private mode. */ }
}

function browserRenderHistory() {
  const list = $('#browser-history-list');
  const count = $('#browser-history-count');
  if (!list || !count) return;
  count.textContent = String(browserState.history.length);
  list.replaceChildren();
  if (!browserState.history.length) {
    list.innerHTML = '<div class="empty">暂无浏览记录</div>';
    return;
  }
  [...browserState.history].reverse().forEach((url, offset) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'browser-history-item';
    button.title = url;
    button.textContent = url.replace(/^https?:\/\//i, '');
    button.addEventListener('click', () => {
      const historyIndex = browserState.history.lastIndexOf(url);
      if (historyIndex >= 0) {
        browserState.index = historyIndex;
        browserNavigate(url, { fromHistory: true });
      }
    });
    if (browserState.history.length - 1 - offset === browserState.index) button.classList.add('active');
    list.appendChild(button);
  });
}

function browserUpdateControls() {
  $('#browser-back').disabled = browserState.index <= 0;
  $('#browser-forward').disabled = browserState.index < 0 || browserState.index >= browserState.history.length - 1;
  $('#browser-external').disabled = !browserState.currentUrl;
}

function browserSetStatus(message, error = false) {
  const status = $('#browser-status');
  if (!status) return;
  status.textContent = message;
  status.classList.toggle('error', error);
}

function browserLikelyBlocksEmbedding(url) {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return /(^|\.)yandex\.[a-z.]+$/.test(host)
      || /(^|\.)google\.[a-z.]+$/.test(host)
      || /(^|\.)bing\.com$/.test(host)
      || /(^|\.)duckduckgo\.com$/.test(host);
  } catch { return false; }
}

function browserSetBlockedNotice(url) {
  const blocked = $('#browser-blocked');
  if (!blocked) return;
  blocked.classList.toggle('hidden', !browserLikelyBlocksEmbedding(url));
}

function browserNormalizeInput(value) {
  const raw = String(value || '').trim();
  if (!raw) return null;
  if (/^(?:javascript|data|file|vbscript):/i.test(raw)) return null;
  const candidate = /^[a-z][a-z\d+.-]*:\/\//i.test(raw) ? raw : (/^[^\s/?#]+\.[^\s/?#]+(?:[/?#].*)?$/i.test(raw) ? `https://${raw}` : `https://www.bing.com/search?q=${encodeURIComponent(raw)}`);
  try {
    const parsed = new URL(candidate);
    if (!['http:', 'https:'].includes(parsed.protocol)) return null;
    return parsed.href;
  } catch { return null; }
}

function browserNavigate(value, options = {}) {
  const url = browserNormalizeInput(value);
  if (!url) {
    browserSetStatus('请输入 http(s) 网址或搜索内容', true);
    $('#browser-address').focus();
    return false;
  }
  const { fromHistory = false, replace = false } = options;
  const frame = $('#browser-frame');
  browserState.currentUrl = url;
  $('#browser-address').value = url;
  $('#browser-empty').classList.add('hidden');
  browserSetBlockedNotice(url);
  browserSetStatus(browserLikelyBlocksEmbedding(url)
    ? '正在加载；该站点常见地禁止 iframe 嵌入，可使用隔离窗口打开'
    : '正在加载网页…');
  if (!fromHistory) {
    const current = browserState.history[browserState.index];
    if (replace && browserState.index >= 0) browserState.history[browserState.index] = url;
    else if (current !== url) {
      browserState.history = browserState.history.slice(0, browserState.index + 1);
      browserState.history.push(url);
      browserState.history = browserState.history.slice(-20);
      browserState.index = browserState.history.length - 1;
    }
    browserSaveHistory();
  }
  frame.removeAttribute('src');
  frame.src = url;
  browserRenderHistory();
  browserUpdateControls();
  return true;
}

function browserGoBack() {
  if (browserState.index <= 0) return;
  browserState.index--;
  browserNavigate(browserState.history[browserState.index], { fromHistory: true });
}

function browserGoForward() {
  if (browserState.index >= browserState.history.length - 1) return;
  browserState.index++;
  browserNavigate(browserState.history[browserState.index], { fromHistory: true });
}

function browserReload() {
  if (!browserState.currentUrl) return;
  const frame = $('#browser-frame');
  browserSetStatus('正在刷新网页…');
  frame.src = browserState.currentUrl;
}

async function browserOpenIsolated() {
  if (!browserState.currentUrl) return;
  const button = $('#browser-external');
  button.disabled = true;
  browserSetStatus('正在打开独立 Edge 隐私窗口…');
  try {
    await api('/open-edge', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({ url: browserState.currentUrl })
    });
    browserSetStatus('已在独立 Edge 隐私窗口中打开；当前页面仍受沙箱限制');
  } catch (error) {
    browserSetStatus(`无法打开隔离窗口：${error.message}`, true);
  } finally {
    browserUpdateControls();
  }
}

function browserClearHistory() {
  browserState.history = [];
  browserState.index = -1;
  browserSaveHistory();
  browserRenderHistory();
  browserUpdateControls();
}

function mediaIndex() { return completedJobs.findIndex((job) => job.id === selectedMediaId); }

function applyPlayerVolume() {
  const slider = $('#playback-volume');
  const volume = Math.max(0, Math.min(200, Number(slider.value) || 0));
  $('#playback-volume-value').value = `${volume}%`;
  $('#playback-volume-value').textContent = `${volume}%`;
  try { localStorage.setItem('player-volume', String(volume)); } catch {}
  const player = $('#local-player');
  if (!playerAudioContext && volume > 100 && (window.AudioContext || window.webkitAudioContext)) {
    try {
      playerAudioContext = new (window.AudioContext || window.webkitAudioContext)();
      playerAudioSource = playerAudioContext.createMediaElementSource(player);
      playerAudioGain = playerAudioContext.createGain();
      playerAudioSource.connect(playerAudioGain);
      playerAudioGain.connect(playerAudioContext.destination);
      player.volume = 1;
    } catch {
      playerAudioContext = null;
      playerAudioSource = null;
      playerAudioGain = null;
    }
  }
  if (playerAudioGain) {
    player.volume = 1;
    playerAudioGain.gain.value = volume / 100;
  } else {
    player.volume = Math.min(1, volume / 100);
  }
}

function selectMedia(id, autoplay = false) {
  const job = completedJobs.find((item) => item.id === id);
  if (!job) return;
  selectedMediaId = id;
  $$('.media-item').forEach((item) => item.classList.toggle('active', item.dataset.id === id));
  const player = $('#local-player');
  const mediaUrl = job.mediaUrl || `/media?id=${encodeURIComponent(job.id)}`;
  if (player.getAttribute('src') !== mediaUrl) player.src = mediaUrl;
  player.playbackRate = Number($('#playback-rate').value);
  applyPlayerVolume();
  player.classList.add('ready');
  $('#player-empty').classList.add('hidden');
  $('#player-title').textContent = job.filename;
  const source = job.sourcePage || '';
  const sourceLink = $('#source-link');
  sourceLink.href = source || '#';
  sourceLink.classList.toggle('hidden', !source);
  const frame = $('#page-preview');
  if (source) {
    const previewUrl = job.pagePreviewUrl || `/page-preview?id=${encodeURIComponent(job.id)}`;
    const requestId = ++sourcePreviewRequest;
    frame.removeAttribute('src');
    frame.srcdoc = '<p style="font:14px system-ui;color:#64748b;padding:20px">正在加载来源页面…</p>';
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 25000);
    fetch(previewUrl, { cache: 'no-store', signal: controller.signal })
      .then(async (response) => {
        const html = await response.text();
        if (!response.ok) {
          let message = `来源页面加载失败（HTTP ${response.status}）`;
          try { const data = JSON.parse(html); if (data.error) message = `来源页面加载失败：${data.error}`; } catch {}
          throw new Error(message);
        }
        return html;
      })
      .then((html) => {
        if (selectedMediaId !== id || requestId !== sourcePreviewRequest) return;
        frame.removeAttribute('src');
        frame.srcdoc = html;
      })
      .catch((error) => {
        if (selectedMediaId !== id || requestId !== sourcePreviewRequest) return;
        const message = error?.name === 'AbortError' ? '来源页面加载超时，请点击“打开原页面”查看。' : (error?.message || '来源页面加载失败。');
        frame.removeAttribute('src');
        frame.srcdoc = `<p style="font:14px system-ui;color:#64748b;padding:20px">${escapeHtml(message)}</p>`;
      })
      .finally(() => window.clearTimeout(timeout));
  } else {
    ++sourcePreviewRequest;
    frame.removeAttribute('src');
    frame.srcdoc = '<p style="font:14px system-ui;color:#64748b;padding:20px">此视频没有来源网页记录。</p>';
  }
  if (autoplay) player.play().catch(() => {});
}

function renderMediaLibrary(jobs, force = false) {
  completedJobs = jobs.filter((job) => job.status === 'done' || job.mediaUrl);
  for (const id of [...selectedMediaIds]) {
    if (!completedJobs.some((job) => job.id === id)) selectedMediaIds.delete(id);
  }
  const selectedIndex = mediaIndex();
  if (selectedIndex >= mediaVisibleLimit) mediaVisibleLimit = Math.ceil((selectedIndex + 1) / 60) * 60;
  const signature = `${mediaVisibleLimit}|${completedJobs.map((job) => `${job.id}:${job.size}`).join('|')}`;
  if (!force && signature === librarySignature) return;
  librarySignature = signature;
  const list = $('#media-list');
  list.replaceChildren();
  $('#library-count').textContent = `${completedJobs.length} 个视频`;
  if (!completedJobs.length) {
    list.innerHTML = '<div class="empty">暂无已完成视频</div>';
    selectedMediaId = '';
    updateMediaSelection();
    return;
  }
  for (const job of completedJobs.slice(0, mediaVisibleLimit)) {
    const item = document.createElement('div');
    item.className = 'media-item';
    item.dataset.id = job.id;
    item.innerHTML = `<input class="media-check" type="checkbox" aria-label="选择 ${escapeHtml(job.filename)}" ${selectedMediaIds.has(job.id) ? 'checked' : ''}><button type="button" class="media-open"><span class="media-play">▶</span><span class="media-copy"><strong title="${escapeHtml(job.filename)}">${escapeHtml(job.filename)}</strong><small>${[formatDuration(job.duration), formatBytes(job.size)].filter(Boolean).join(' · ') || '本地 MP4'}</small></span></button>`;
    const checkbox = $('.media-check', item);
    checkbox.addEventListener('click', (event) => event.stopPropagation());
    checkbox.addEventListener('change', () => {
      if (checkbox.checked) selectedMediaIds.add(job.id);
      else selectedMediaIds.delete(job.id);
      updateMediaSelection();
    });
    $('.media-open', item).addEventListener('click', () => selectMedia(job.id, true));
    list.appendChild(item);
  }
  if (completedJobs.length > mediaVisibleLimit) {
    const more = document.createElement('button');
    more.className = 'button small ghost';
    more.textContent = `显示更多（剩余 ${completedJobs.length - mediaVisibleLimit}）`;
    more.addEventListener('click', () => { mediaVisibleLimit += 60; renderMediaLibrary(completedJobs, true); });
    list.appendChild(more);
  }
  updateMediaSelection();
  if (selectedMediaId && completedJobs.some((job) => job.id === selectedMediaId)) selectMedia(selectedMediaId, false);
  else if (selectedMediaId) selectedMediaId = '';
}

function updateMediaSelection() {
  const validIds = new Set(completedJobs.map((job) => job.id));
  for (const id of [...selectedMediaIds]) if (!validIds.has(id)) selectedMediaIds.delete(id);
  const selected = selectedMediaIds.size;
  $('#media-selected-count').textContent = `已选择 ${selected} 个`;
  $('#delete-media').disabled = selected === 0;
  const selectAll = $('#select-all-media');
  selectAll.disabled = completedJobs.length === 0;
  selectAll.textContent = completedJobs.length > 0 && selected === completedJobs.length ? '取消全选' : '全选';
  selectAll.setAttribute('aria-pressed', completedJobs.length > 0 && selected === completedJobs.length ? 'true' : 'false');
}

async function deleteSelectedMedia() {
  const ids = [...selectedMediaIds];
  if (!ids.length) return;
  const selectedNames = completedJobs.filter((job) => ids.includes(job.id)).map((job) => job.filename);
  const suffix = selectedNames.length > 1 ? `\n\n共 ${selectedNames.length} 个视频。` : `\n\n${selectedNames[0] || ''}`;
  if (!window.confirm(`确定永久删除所选视频吗？\n如果视频位于独占下载文件夹中，该文件夹及来源信息也会一并删除。删除后不会进入回收站，文件无法恢复。${suffix}`)) return;
  if (selectedMediaId && ids.includes(selectedMediaId)) {
    const player = $('#local-player');
    player.pause();
    player.removeAttribute('src');
    player.load();
    player.classList.remove('ready');
    $('#player-empty').classList.remove('hidden');
    $('#player-title').textContent = '';
    selectedMediaId = '';
  }
  const button = $('#delete-media');
  button.disabled = true;
  button.textContent = '删除中…';
  try {
    const result = await api('/delete-media', {
      method: 'POST',
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: JSON.stringify({ ids })
    });
    ids.forEach((id) => selectedMediaIds.delete(id));
    await loadTasks(true);
    if (result.errors?.length) window.alert(`已删除 ${result.deleted || 0} 个视频，但有部分失败：\n${result.errors.join('\n')}`);
  } catch (error) {
    window.alert(`删除失败：${error.message}`);
  } finally {
    button.textContent = '永久删除视频及文件夹';
    updateMediaSelection();
  }
}

function moveMedia(offset) {
  if (!completedJobs.length) return;
  const current = mediaIndex();
  const next = (Math.max(0, current) + offset + completedJobs.length) % completedJobs.length;
  selectMedia(completedJobs[next].id, true);
}

const labels = { queued:'排队中', running:'下载中', validating:'校验中', done:'已完成', filtered:'已过滤', error:'失败', canceled:'已取消' };
function sortJobsNewest(jobs) {
  return [...jobs].sort((left, right) => {
    const leftTime = Date.parse(left.created || '') || 0;
    const rightTime = Date.parse(right.created || '') || 0;
    return rightTime - leftTime || String(right.id || '').localeCompare(String(left.id || ''));
  });
}

function taskMatchesSearch(job) {
  const query = taskSearch.trim().toLocaleLowerCase();
  if (!query) return true;
  return [job.filename, job.sourcePage, job.error].some((value) => String(value || '').toLocaleLowerCase().includes(query));
}

function includeJob(job) {
  if (job.status === 'deleted') return false;
  if (currentFilter === 'active' && !(job.status === 'queued' || job.status === 'running' || job.status === 'validating')) return false;
  if (currentFilter === 'done' && !(job.status === 'done' || job.status === 'filtered')) return false;
  if (currentFilter === 'error' && !(job.status === 'error' || job.status === 'canceled')) return false;
  return taskMatchesSearch(job);
}

function canDeleteTaskRecord(job) {
  return !['queued', 'running', 'validating'].includes(job.status);
}

async function jobAction(path, id) { await api(`${path}?id=${encodeURIComponent(id)}`, { method:'POST' }); await loadTasks(); }

async function copySourceUrl(button, url) {
  const value = String(url || '').trim();
  if (!value) { window.alert('该任务没有可复制的来源页面链接'); return; }
  let copied = false;
  try {
    await navigator.clipboard.writeText(value);
    copied = true;
  } catch {
    const input = document.createElement('textarea');
    input.value = value;
    input.setAttribute('readonly', '');
    input.style.position = 'fixed';
    input.style.opacity = '0';
    document.body.appendChild(input);
    input.select();
    try { copied = document.execCommand('copy'); } catch {}
    input.remove();
  }
  if (!copied) { window.alert('复制失败，请从任务的来源页面手动复制链接'); return; }
  const original = button.textContent;
  button.textContent = '已复制';
  button.disabled = true;
  window.setTimeout(() => { button.textContent = original; button.disabled = false; }, 1400);
}

function updateTaskSelection(visibleJobs = []) {
  const knownIds = new Set(taskJobs.filter(canDeleteTaskRecord).map((job) => job.id));
  for (const id of [...selectedTaskIds]) if (!knownIds.has(id)) selectedTaskIds.delete(id);
  const visibleIds = visibleJobs.filter(canDeleteTaskRecord).map((job) => job.id);
  const selectedVisible = visibleIds.filter((id) => selectedTaskIds.has(id)).length;
  const selectAll = $('#task-select-all');
  selectAll.checked = visibleIds.length > 0 && selectedVisible === visibleIds.length;
  selectAll.indeterminate = selectedVisible > 0 && selectedVisible < visibleIds.length;
  selectAll.disabled = visibleIds.length === 0;
  $('#task-selected-count').textContent = `已选 ${selectedTaskIds.size} 条`;
  $('#delete-selected-tasks').disabled = selectedTaskIds.size === 0;
}

function clearTaskSelection() {
  selectedTaskIds.clear();
  updateTaskSelection([]);
}

async function deleteTaskRecords(ids) {
  const uniqueIds = [...new Set(ids)].filter(Boolean);
  if (!uniqueIds.length) return;
  const names = taskJobs.filter((job) => uniqueIds.includes(job.id)).map((job) => job.filename);
  const suffix = names.length > 1 ? `\n\n共 ${names.length} 条记录。` : `\n\n${names[0] || ''}`;
  if (!window.confirm(`确定删除所选下载记录吗？\n只移除记录，不会删除任何视频文件或下载文件夹。${suffix}`)) return;
  const button = $('#delete-selected-tasks');
  button.disabled = true;
  try {
    const result = await api('/delete-jobs', {
      method: 'POST',
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: JSON.stringify({ ids: uniqueIds })
    });
    uniqueIds.forEach((id) => selectedTaskIds.delete(id));
    await loadTasks(true);
    const messages = [];
    if (result.preservedMp4 > 0) messages.push(`检测到 ${result.preservedMp4} 个 MP4，视频文件和所在文件夹均已保留。`);
    if (result.errors?.length) messages.push(`有部分记录无法删除：\n${result.errors.join('\n')}`);
    if (messages.length) window.alert(`已删除 ${result.deleted || 0} 条记录。\n${messages.join('\n')}`);
  } catch (error) {
    window.alert(`删除记录失败：${error.message}`);
  } finally {
    updateTaskSelection([]);
  }
}

function renderTasks(jobs) {
  const orderedJobs = sortJobsNewest(jobs);
  $('#running-count').textContent = jobs.filter((job) => job.status === 'running').length;
  $('#validating-count').textContent = jobs.filter((job) => job.status === 'validating').length;
  $('#queued-count').textContent = jobs.filter((job) => job.status === 'queued').length;
  const visible = orderedJobs.filter(includeJob);
  tasksEl.replaceChildren();
  if (!visible.length) {
    tasksEl.innerHTML = '<div class="empty">当前筛选没有任务</div>';
    updateTaskSelection(visible);
    return;
  }
  const template = $('#task-template');
  for (const job of visible.slice(0, taskVisibleLimit)) {
    const card = template.content.firstElementChild.cloneNode(true);
    const checkbox = card.querySelector('.task-check');
    checkbox.disabled = !canDeleteTaskRecord(job);
    checkbox.title = checkbox.disabled ? '进行中的任务请先取消' : '选择下载记录';
    checkbox.checked = selectedTaskIds.has(job.id);
    checkbox.addEventListener('change', () => {
      if (checkbox.checked) selectedTaskIds.add(job.id);
      else selectedTaskIds.delete(job.id);
      updateTaskSelection(visible);
    });
    card.querySelector('.task-name').textContent = job.filename;
    const badge = card.querySelector('.status-badge');
    badge.textContent = labels[job.status] || job.status;
    badge.classList.add(job.status);
    const created = job.created ? new Date(job.created).toLocaleString('zh-CN', { hour12:false }) : '';
    card.querySelector('.task-meta').textContent = [created, formatBytes(job.size), job.speed].filter(Boolean).join(' · ');
    const percent = job.status === 'done' ? 100 : Number(job.progress || 0);
    card.querySelector('.progress-bar').style.width = `${Math.max(0, Math.min(100, percent))}%`;
    card.querySelector('.progress-text').textContent = job.status === 'running'
      ? `${percent ? percent.toFixed(1) + '% · ' : ''}${job.time || '正在连接视频源'}${job.duration ? ' / ' + formatDuration(job.duration) : ''}`
      : job.status === 'validating' ? '下载完成，正在校验文件完整性'
      : job.status === 'queued' ? '等待空闲下载槽' : job.status === 'done' ? '下载、封装和校验已完成' : job.status === 'filtered' ? '视频不足 1 分钟，文件已删除' : '';
    if (job.error) { const error = card.querySelector('.task-error'); error.textContent = job.error; error.classList.add('visible'); }
    const actions = card.querySelector('.task-actions');
    if (job.status === 'queued' || job.status === 'running' || job.status === 'validating') {
      const cancel = document.createElement('button'); cancel.className = 'button small danger'; cancel.textContent = '取消'; cancel.onclick = () => jobAction('/cancel', job.id); actions.appendChild(cancel);
    }
    if (job.status === 'error' || job.status === 'canceled') {
      const retry = document.createElement('button'); retry.className = 'button small ghost'; retry.textContent = '重试'; retry.onclick = () => jobAction('/retry', job.id); actions.appendChild(retry);
      const copy = document.createElement('button'); copy.className = 'button small ghost'; copy.textContent = '复制来源链接'; copy.title = '复制视频所在的来源页面地址'; copy.onclick = () => copySourceUrl(copy, job.sourcePage); actions.appendChild(copy);
    }
    if (job.status === 'done') {
      const preview = document.createElement('button'); preview.className = 'button small ghost'; preview.textContent = '预览'; preview.onclick = () => { switchView('preview-view'); selectMedia(job.id, true); }; actions.appendChild(preview);
      const save = document.createElement('a'); save.className = 'button small primary'; save.textContent = '保存 MP4'; save.href = `/file?id=${encodeURIComponent(job.id)}`; actions.appendChild(save);
      const folder = document.createElement('button'); folder.className = 'button small ghost'; folder.textContent = '打开文件夹'; folder.onclick = () => jobAction('/open-folder', job.id); actions.appendChild(folder);
    }
    if (canDeleteTaskRecord(job)) {
      const remove = document.createElement('button'); remove.className = 'button small ghost'; remove.textContent = '仅删除记录'; remove.title = '保留视频文件和下载文件夹'; remove.onclick = () => deleteTaskRecords([job.id]); actions.appendChild(remove);
    }
    tasksEl.appendChild(card);
  }
  if (visible.length > taskVisibleLimit) {
    const more = document.createElement('button');
    more.className = 'button small ghost';
    more.textContent = `显示更多（剩余 ${visible.length - taskVisibleLimit}）`;
    more.onclick = () => { taskVisibleLimit += 60; renderTasks(orderedJobs); };
    tasksEl.appendChild(more);
  }
  updateTaskSelection(visible);
}

async function loadTasks(forceLibrary = false) {
  if (tasksLoading) return;
  tasksLoading = true;
  try {
    const data = await api('/jobs');
    const jobs = sortJobsNewest(data.jobs || []);
    taskJobs = jobs;
    renderTasks(jobs);
    mediaRefreshTick++;
    if ($('#preview-view').classList.contains('active') && (forceLibrary || mediaRefreshTick % 4 === 0 || !librarySignature)) {
      const mediaData = await api('/media-list');
      renderMediaLibrary(mediaData.media || [], forceLibrary);
    }
  } catch { tasksEl.innerHTML = '<div class="empty">任务服务暂时不可用</div>'; }
  finally { tasksLoading = false; }
}

$$('.workspace-tab').forEach((tab) => tab.addEventListener('click', () => switchView(tab.dataset.view)));
$('#analyze').addEventListener('click', analyze);
$('#clear-input').addEventListener('click', () => { $('#page-urls').value = ''; $('#analyze-message').textContent = ''; });
$('#category-analyze').addEventListener('click', analyzeCategory);
$('#enqueue-single').addEventListener('click', () => enqueueSelected('single'));
$('#enqueue-batch').addEventListener('click', () => enqueueSelected('batch'));
['single','batch'].forEach((mode) => modeElements(mode).selectAll.addEventListener('change', (event) => { $$(`.stream-check[data-mode="${mode}"]:not(:disabled)`).forEach((input) => { input.checked = event.target.checked; }); updateSelectedCount(mode); }));
$('#refresh-tasks').addEventListener('click', () => loadTasks(true));
$('#refresh-library').addEventListener('click', () => loadTasks(true));
$('#task-search').addEventListener('input', (event) => {
  taskSearch = event.target.value;
  taskVisibleLimit = 60;
  clearTaskSelection();
  renderTasks(taskJobs);
});
$('#task-select-all').addEventListener('change', (event) => {
  const visible = taskJobs.filter(includeJob).filter(canDeleteTaskRecord);
  if (event.target.checked) visible.forEach((job) => selectedTaskIds.add(job.id));
  else visible.forEach((job) => selectedTaskIds.delete(job.id));
  renderTasks(taskJobs);
});
$('#delete-selected-tasks').addEventListener('click', () => deleteTaskRecords([...selectedTaskIds]));
$('#select-all-media').addEventListener('click', () => {
  const selectAll = selectedMediaIds.size !== completedJobs.length;
  selectedMediaIds.clear();
  if (selectAll) completedJobs.forEach((job) => selectedMediaIds.add(job.id));
  $$('.media-check').forEach((input) => { input.checked = selectAll; });
  updateMediaSelection();
});
$('#delete-media').addEventListener('click', deleteSelectedMedia);
$('#prev-video').addEventListener('click', () => moveMedia(-1));
$('#next-video').addEventListener('click', () => moveMedia(1));
$('#playback-rate').addEventListener('change', (event) => { $('#local-player').playbackRate = Number(event.target.value); });
$('#playback-volume').addEventListener('input', applyPlayerVolume);
$('#local-player').addEventListener('play', () => {
  if (playerAudioContext?.state === 'suspended') playerAudioContext.resume().catch(() => {});
});
try {
  const savedVolume = Number(localStorage.getItem('player-volume'));
  if (Number.isFinite(savedVolume)) $('#playback-volume').value = String(Math.max(0, Math.min(200, savedVolume)));
} catch {}
applyPlayerVolume();
$('#local-player').addEventListener('ended', () => moveMedia(1));
browserLoadHistory();
browserRenderHistory();
browserUpdateControls();
$('#browser-address-form').addEventListener('submit', (event) => {
  event.preventDefault();
  browserNavigate($('#browser-address').value);
});
$('#browser-back').addEventListener('click', browserGoBack);
$('#browser-forward').addEventListener('click', browserGoForward);
$('#browser-reload').addEventListener('click', browserReload);
$('#browser-clear-history').addEventListener('click', browserClearHistory);
$('#browser-external').addEventListener('click', browserOpenIsolated);
$('#browser-blocked-open').addEventListener('click', browserOpenIsolated);
$('#browser-frame').addEventListener('load', () => {
  browserSetStatus(browserLikelyBlocksEmbedding(browserState.currentUrl)
    ? '已尝试加载；该站点可能拒绝 iframe 嵌入，请使用隔离窗口打开'
    : '网页已加载，沙箱限制仍生效');
});
$$('.filter').forEach((button) => button.addEventListener('click', () => { $$('.filter').forEach((item) => item.classList.remove('active')); button.classList.add('active'); currentFilter = button.dataset.filter; taskVisibleLimit = 60; clearTaskSelection(); loadTasks(); }));

checkService();
loadTasks();
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) { checkService(); loadTasks(true); }
});
setInterval(() => { if (!document.hidden) loadTasks(); }, 3000);
setInterval(() => { if (!document.hidden) checkService(); }, 10000);
