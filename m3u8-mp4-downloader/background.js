const HELPER = 'http://127.0.0.1:17890';
const ALARM = 'm3u8-queue-poll';
let polling = false;

chrome.runtime.onInstalled.addListener(() => chrome.alarms.create(ALARM, { periodInMinutes: 0.5 }));
chrome.runtime.onStartup.addListener(() => chrome.alarms.create(ALARM, { periodInMinutes: 0.5 }));
chrome.alarms.create(ALARM, { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => { if (alarm.name === ALARM) pollQueue(); });

async function pollQueue() {
  if (polling) return;
  polling = true;
  try {
    const response = await fetch(`${HELPER}/jobs`, { signal: AbortSignal.timeout(5000) });
    if (!response.ok) return;
    const { jobs = [] } = await response.json();
    for (const job of jobs) {
      if (job.status !== 'done' || job.downloaded) continue;
      const key = `browser-download-${job.id}`;
      const saved = await chrome.storage.local.get(key);
      if (saved[key] && saved[key].status !== 'error') continue;
      await chrome.storage.local.set({ [key]: { status: 'starting', filename: job.filename } });
      try {
        const downloadId = await chrome.downloads.download({ url: `${HELPER}/file?id=${encodeURIComponent(job.id)}`, filename: job.filename, saveAs: false });
        await chrome.storage.local.set({ [key]: { status: 'downloading', downloadId, filename: job.filename } });
      } catch (error) {
        await chrome.storage.local.set({ [key]: { status: 'error', error: error.message, filename: job.filename } });
      }
    }
  } catch { /* The helper may be stopped; the next alarm will retry. */ }
  finally { polling = false; }
}

chrome.downloads.onChanged.addListener(async (delta) => {
  if (!delta.state || !delta.id) return;
  const all = await chrome.storage.local.get(null);
  for (const [key, value] of Object.entries(all)) {
    if (!key.startsWith('browser-download-') || value.downloadId !== delta.id) continue;
    const state = delta.state.current;
    const nextStatus = state === 'complete' ? 'saved' : state === 'interrupted' ? 'error' : value.status;
    await chrome.storage.local.set({ [key]: { ...value, status: nextStatus, error: delta.error?.current || '' } });
    if (state === 'complete') await fetch(`${HELPER}/ack?id=${encodeURIComponent(key.slice('browser-download-'.length))}`, { method: 'POST' }).catch(() => {});
    break;
  }
});
