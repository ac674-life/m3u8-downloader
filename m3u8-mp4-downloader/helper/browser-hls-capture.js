const { chromium } = require(process.env.M3U8_PLAYWRIGHT_PATH);

const urls = process.env.M3U8_CAPTURE_URL
  ? [process.env.M3U8_CAPTURE_URL]
  : JSON.parse(process.argv[2] || '[]');
const executablePath = process.env.M3U8_BROWSER_PATH;

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath,
    args: [
      '--disable-gpu',
      '--no-first-run',
      '--disable-background-networking',
      '--no-proxy-server',
    ],
  });

  try {
    const results = [];
    const context = await browser.newContext({
      userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36',
    });

    for (const url of urls.slice(0, 20)) {
      const page = await context.newPage();
      await page.addInitScript(() => {
        let hlsConstructor;
        window.__m3u8CapturedHls = [];
        Object.defineProperty(window, 'Hls', {
          configurable: true,
          get() { return hlsConstructor; },
          set(value) {
            if (typeof value !== 'function') {
              hlsConstructor = value;
              return;
            }
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
      const addStream = value => {
        try {
          const candidate = new URL(value, url);
          if (/\.(m3u8|mp4)(?:[?#]|$)/i.test(candidate.href)) streams.add(candidate.href);
        } catch {}
      };
      page.on('request', request => addStream(request.url()));
      page.on('response', response => addStream(response.url()));
      page.on('console', message => diagnostics.push(`${message.type()}: ${message.text()}`));
      page.on('pageerror', error => diagnostics.push(`pageerror: ${error.message}`));

      let title = url;
      let error = '';
      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
        title = await page.title().catch(() => url);
        await page.waitForTimeout(2500);
        await page.evaluate(() => {
          for (const element of document.querySelectorAll('video, [id*=player], [class*=player]')) {
            try {
              element.scrollIntoView({ block: 'center' });
              element.click();
            } catch {}
          }
          const video = document.querySelector('video');
          if (video) video.play().catch(() => {});
        });

        let previousSignature = '';
        let stablePolls = 0;
        for (let attempt = 0; attempt < 20; attempt += 1) {
          await page.waitForTimeout(500);
          const signature = await page.evaluate(() => (window.__m3u8CapturedHls || [])
            .map(instance => {
              const details = instance.latestLevelDetails || instance.levels?.find(level => level.details)?.details;
              const fragments = details?.fragments || [];
              return `${fragments.length}:${fragments.at(-1)?.url || ''}`;
            }).join('|'));
          if (signature && /[1-9]\d*:/.test(signature)) {
            stablePolls = signature === previousSignature ? stablePolls + 1 : 0;
            if (stablePolls >= 2) break;
          }
          previousSignature = signature;
        }
      } catch (captureError) {
        error = captureError.message;
      }

      const player = await page.evaluate(() => {
        const video = document.querySelector('video');
        const hlsInstances = (window.__m3u8CapturedHls || []).map(instance => {
          const details = instance.latestLevelDetails || instance.levels?.find(level => level.details)?.details;
          return {
            url: instance.url || '',
            totalDuration: Number(details?.totalduration) || 0,
            live: Boolean(details?.live),
            fragments: details?.fragments?.map(fragment => ({
              url: fragment.url || '',
              duration: Number(fragment.duration) || 0,
              sn: fragment.sn,
              cc: fragment.cc,
              initSegment: fragment.initSegment?.url || '',
              decryptData: fragment.decryptdata ? {
                method: fragment.decryptdata.method || '',
                uri: fragment.decryptdata.uri || '',
                iv: fragment.decryptdata.iv ? Array.from(fragment.decryptdata.iv) : [],
                key: fragment.decryptdata.key ? Array.from(fragment.decryptdata.key) : [],
              } : null,
            })).filter(fragment => fragment.url && fragment.duration > 0) || [],
          };
        });
        return {
          duration: Number.isFinite(video?.duration) ? video.duration : null,
          hlsInstances,
        };
      }).catch(() => null);

      const captures = (player?.hlsInstances || []).filter(capture => capture.fragments.length > 0);
      results.push({
        pageUrl: url,
        title,
        streams: [...streams],
        captures,
        duration: player?.duration || captures[0]?.totalDuration || 0,
        error,
        diagnostics: diagnostics.slice(-20),
      });
      await page.close();
    }

    await context.close();
    process.stdout.write(JSON.stringify({ pages: results }));
  } finally {
    await browser.close();
  }
})().catch(error => {
  process.stderr.write(error.stack || String(error));
  process.exit(1);
});
