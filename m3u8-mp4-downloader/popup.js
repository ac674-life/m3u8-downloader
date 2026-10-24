const HELPER = 'http://127.0.0.1:17890';
const streamsEl = document.getElementById('streams');
const jobsEl = document.getElementById('jobs');
const noticeEl = document.getElementById('notice');
const helperStateEl = document.getElementById('helper-state');
const pageNameEl = document.getElementById('page-name');
const streams = new Map();

function setNotice(text, kind = '') { noticeEl.textContent = text; noticeEl.className = `notice ${kind}`; }
function normalizeUrl(value, baseUrl) { try { const url = new URL(value.replaceAll('\\/', '/').replaceAll('&amp;', '&'), baseUrl); return /^https?:$/.test(url.protocol) ? url.href : null; } catch { return null; } }
function scanPage() {
  const urls = new Set();
  const add = (value) => { const url = normalizeUrl(value, location.href); if (url && /\.(m3u8|mp4)(?:[?#]|$)/i.test(url)) urls.add(url); };
  document.querySelectorAll('video, source, a').forEach((el) => add(el.currentSrc || el.src || el.href || ''));
  performance.getEntriesByType('resource').forEach((entry) => add(entry.name));
  const matches = (document.documentElement?.outerHTML || '').match(/[^"'\s<>]+\.(?:m3u8|mp4)(?:\?[^"'\s<>]*)?/gi) || [];
  matches.forEach(add);
  return { title: document.title, urls: [...urls] };
}
async function getPageInfo() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) throw new Error('无法取得当前标签页');
  pageNameEl.textContent = tab.title || tab.url || '当前页面';
  try { const result = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: scanPage }); return { tab, ...(result[0]?.result || { urls: [] }) }; }
  catch { throw new Error('当前页面禁止扩展读取，请手动粘贴 m3u8 地址'); }
}
async function checkHelper() { try { const r = await fetch(`${HELPER}/health`, { signal: AbortSignal.timeout(1500) }); if (!r.ok) throw new Error(); helperStateEl.textContent = '本地辅助程序已连接'; helperStateEl.style.color = '#047857'; } catch { helperStateEl.textContent = '未连接本地辅助程序'; helperStateEl.style.color = '#b45309'; } }
function safeFilename(url, index) { try { const name = decodeURIComponent(new URL(url).pathname.split('/').pop() || 'video'); return (name.replace(/\.[^.]+$/, '').replace(/[<>:"/\\|?*\x00-\x1F]/g, '_').slice(0, 80) || `video-${index}`) + '.mp4'; } catch { return `video-${index}.mp4`; } }
function addStream(url) { if (!streams.has(url)) { const item = { url, index: streams.size + 1 }; streams.set(url, item); renderStream(item); } }
function renderStream(item) {
  const card = document.createElement('article'); card.className = 'stream';
  const isM3u8 = /\.m3u8(?:[?#]|$)/i.test(item.url);
  card.innerHTML = `<div class="stream-top"><span class="stream-type">${isM3u8 ? 'HLS / m3u8' : '视频直链'}</span><span>${item.index}</span></div><div class="stream-url" title="${item.url.replaceAll('"', '&quot;')}">${item.url}</div><div class="stream-controls"><input class="filename" value="${safeFilename(item.url, item.index)}" aria-label="文件名"><button class="primary download">加入队列</button></div>`;
  const button = card.querySelector('.download'); const filename = card.querySelector('.filename');
  button.addEventListener('click', async () => {
    button.disabled = true; button.textContent = '正在排队…';
    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      const response = await fetch(`${HELPER}/download`, { method: 'POST', headers: { 'Content-Type': 'application/json; charset=utf-8' }, body: JSON.stringify({ url: item.url, filename: filename.value.trim() || `video-${item.index}.mp4`, referer: tab?.url || '' }) });
      const data = await response.json(); if (!response.ok) throw new Error(data.error || '加入队列失败');
      button.textContent = '已加入队列'; setNotice('任务已保存，空闲时会自动开始', 'success'); await loadJobs();
    } catch (error) { button.disabled = false; button.textContent = '加入队列'; setNotice(error.message || '加入队列失败', 'error'); }
  });
  streamsEl.appendChild(card);
}
const statusText = { queued: '排队中', running: '下载中', done: '已完成', error: '失败', canceled: '已取消' };
async function loadJobs() {
  try {
    const response = await fetch(`${HELPER}/jobs`); const data = await response.json(); if (!response.ok) throw new Error(data.error || '读取任务失败');
    jobsEl.replaceChildren();
    if (!data.jobs?.length) { jobsEl.innerHTML = '<div class="empty">暂无下载任务</div>'; return; }
    const downloadStates = await chrome.storage.local.get(data.jobs.map((job) => `browser-download-${job.id}`));
    data.jobs.forEach((job) => {
      const browserDownload = downloadStates[`browser-download-${job.id}`]; const row = document.createElement('div'); row.className = 'job';
      const statusClass = job.status === 'done' ? 'done' : job.status === 'error' ? 'error' : '';
      let label = statusText[job.status] || job.status; let detail = job.status === 'running' && job.time ? job.time : job.status === 'error' ? (job.error || '未知错误') : job.status === 'queued' ? '等待空闲任务槽' : '';
      if (browserDownload?.status === 'starting' || browserDownload?.status === 'downloading') { label = '保存到本地'; detail = '浏览器正在接收 MP4'; }
      if (browserDownload?.status === 'saved') { label = '已保存'; detail = '文件已保存到下载目录'; }
      if (browserDownload?.status === 'error') { label = '保存失败'; detail = browserDownload.error || '浏览器下载失败'; }
      row.innerHTML = `<div class="job-line"><span class="job-name" title="${job.filename.replaceAll('"', '&quot;')}">${job.filename}</span><span class="job-status ${statusClass}">${label}</span></div><div class="job-detail">${detail}</div>`;
      jobsEl.appendChild(row);
    });
  } catch { jobsEl.innerHTML = '<div class="empty">无法读取任务栏，请确认辅助程序正在运行</div>'; }
}
async function scan() { streams.clear(); streamsEl.replaceChildren(); setNotice('正在扫描页面…'); try { const info = await getPageInfo(); info.urls.forEach(addStream); setNotice(info.urls.length ? `检测到 ${info.urls.length} 个视频地址` : '没有自动检测到视频，可手动粘贴地址'); } catch (error) { setNotice(error.message, 'error'); } }
document.getElementById('refresh').addEventListener('click', scan);
document.getElementById('refresh-jobs').addEventListener('click', loadJobs);
document.getElementById('add-manual').addEventListener('click', () => { const input = document.getElementById('manual-url'); const url = normalizeUrl(input.value.trim(), location.href); if (!url || !/\.(m3u8|mp4)(?:[?#]|$)/i.test(url)) return setNotice('请输入有效的 m3u8 或 MP4 地址', 'error'); addStream(url); input.value = ''; setNotice(`已添加 ${streams.size} 个视频地址`); });
document.getElementById('open-readme').addEventListener('click', () => chrome.tabs.create({ url: chrome.runtime.getURL('README.html') }));
document.getElementById('open-dashboard').addEventListener('click', () => chrome.tabs.create({ url: `${HELPER}/` }));
checkHelper(); scan(); loadJobs(); setInterval(loadJobs, 1500);
