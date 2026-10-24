const { chromium } = require(process.env.M3U8_PLAYWRIGHT_PATH);
const urls = JSON.parse(process.argv[2] || '[]');
const executablePath = process.env.M3U8_BROWSER_PATH;
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath, args: ['--disable-gpu', '--no-first-run', '--disable-background-networking'] });
  try {
    const results = [];
    const context = await browser.newContext({ userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36' });
    for (const url of urls.slice(0, 20)) {
      const page = await context.newPage();
      await page.addInitScript(() => {
        let hlsConstructor;
        window.__m3u8CapturedHls = [];
        Object.defineProperty(window, 'Hls', {
          configurable: true,
          get() { return hlsConstructor; },
          set(value) {
            if (typeof value !== 'function') { hlsConstructor = value; return; }
            hlsConstructor = new Proxy(value, {
              construct(target, args, newTarget) {
                const instance = Reflect.construct(target, args, newTarget);
                window.__m3u8CapturedHls.push(instance);
                return instance;
              },
            });
          },
        });
      });
      const streams = new Set();
      const diagnostics = [];
      const add = value => { try { const u = new URL(value, url); if (/\.(m3u8|mp4)(?:[?#]|$)/i.test(u.href)) streams.add(u.href); } catch {} };
      page.on('request', request => add(request.url()));
      page.on('response', response => add(response.url()));
      page.on('console', message => diagnostics.push(`${message.type()}: ${message.text()}`));
      page.on('pageerror', error => diagnostics.push(`pageerror: ${error.message}`));
      let title = url, error = '';
      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
        title = await page.title().catch(() => url);
        await page.waitForTimeout(7000);
        await page.evaluate(() => { for (const el of document.querySelectorAll('video, [id*=player], [class*=player]')) { try { el.scrollIntoView({block:'center'}); el.click(); } catch {} } });
        await page.waitForTimeout(3000);
      } catch (e) { error = e.message; }
      const player = await page.evaluate(() => {
        const video = document.querySelector('video');
        const container = document.querySelector('.dplayer');
        const globalNames = Object.getOwnPropertyNames(window).filter(name => /(?:^|_)(?:dp|hls)|dplayer/i.test(name));
        const globals = {};
        for (const name of globalNames.slice(0, 40)) {
          try {
            const value = window[name];
            globals[name] = value && typeof value === 'object'
              ? Object.getOwnPropertyNames(value).slice(0, 60)
              : typeof value;
          } catch {}
        }
        const hlsInstances = (window.__m3u8CapturedHls || []).map(instance => {
          const details = instance.latestLevelDetails || instance.levels?.find(level => level.details)?.details;
          return {
            url: instance.url || '',
            levels: instance.levels?.map(level => ({ url: level.url, bitrate: level.bitrate })) || [],
            fragments: details?.fragments?.map(fragment => ({
              url: fragment.url,
              duration: fragment.duration,
              sn: fragment.sn,
              initSegment: fragment.initSegment?.url || '',
            })) || [],
            totalDuration: details?.totalduration || 0,
          };
        });
        return {
          src: video?.src || '',
          currentTime: video?.currentTime || 0,
          duration: Number.isFinite(video?.duration) ? video.duration : null,
          readyState: video?.readyState ?? null,
          networkState: video?.networkState ?? null,
          paused: video?.paused ?? null,
          error: video?.error ? { code: video.error.code, message: video.error.message } : null,
          globals,
          containerProperties: container ? Object.getOwnPropertyNames(container).filter(name => !name.startsWith('on')).slice(0, 80) : [],
          videoProperties: video ? Object.getOwnPropertyNames(video).filter(name => !name.startsWith('on')).slice(0, 80) : [],
          hlsInstances,
        };
      }).catch(() => null);
      results.push({ pageUrl: url, title, streams: [...streams], error, player, diagnostics: diagnostics.slice(-30) });
    }
    await context.close();
    process.stdout.write(JSON.stringify({ pages: results }));
  } finally { await browser.close(); }
})().catch(e => { process.stderr.write(e.stack || String(e)); process.exit(1); });

