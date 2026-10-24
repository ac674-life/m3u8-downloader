const { chromium } = require(process.env.M3U8_PLAYWRIGHT_PATH);
const fs = require('fs');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.M3U8_BROWSER_PATH,
    args: ['--disable-gpu', '--no-first-run'],
  });
  const page = await browser.newPage();
  const events = [];
  page.on('console', message => events.push(`console:${message.type()}:${message.text()}`));
  page.on('pageerror', error => events.push(`pageerror:${error.message}`));
  page.on('response', response => {
    if (/\.m3u8/i.test(response.url())) events.push(`response:${response.status()}:${response.url()}`);
  });
  await page.goto(process.argv[2], { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(5000);
  await page.evaluate(() => {
    const player = document.querySelector('.dplayer');
    const video = document.querySelector('video');
    try { (video || player)?.click(); } catch {}
    try { video?.play(); } catch {}
  });
  await page.waitForTimeout(15000);
  const state = await page.evaluate(() => {
    const video = document.querySelector('video');
    const player = document.querySelector('.dplayer');
    return {
      playerClass: player?.className || '',
      videoSrc: video?.src || '',
      currentTime: video?.currentTime || 0,
      duration: Number.isFinite(video?.duration) ? video.duration : null,
      readyState: video?.readyState ?? null,
      networkState: video?.networkState ?? null,
      paused: video?.paused ?? null,
      error: video?.error ? { code: video.error.code, message: video.error.message } : null,
    };
  });
  const output = JSON.stringify({ state, events: events.slice(-100) });
  if (process.argv[3]) fs.writeFileSync(process.argv[3], output, 'utf8');
  process.stdout.write(output);
  await browser.close();
})().catch(error => {
  process.stderr.write(error.stack || String(error));
  process.exit(1);
});
