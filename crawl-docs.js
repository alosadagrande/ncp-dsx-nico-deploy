const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const HOST = 'a76d4b64-5ac7-c96a-2e66-fca4dcd1ee1f.apps.launchpad.nvidia.com';
const DOCS_BASE = `https://${HOST}/docs`;
const SHELL_URL = `https://${HOST}/launch/docs`;
const OUT_DIR = path.join(__dirname, 'docs');

fs.mkdirSync(OUT_DIR, { recursive: true });

// Collect all .md file paths fetched by the Docsify app
const mdPaths = new Set();

(async () => {
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();

  // Listen to network requests — capture all .md file fetches by Docsify
  context.on('request', req => {
    const url = req.url();
    if (url.includes(HOST) && url.includes('/docs/') && url.match(/\.(md|markdown)(\?|$)/i)) {
      const p = new URL(url).pathname;
      mdPaths.add(p);
      console.log('  discovered:', p);
    }
  });

  const page = await context.newPage();
  console.log('Opening docs — log in if prompted...');
  await page.goto(SHELL_URL, { waitUntil: 'networkidle', timeout: 120000 });
  await page.waitForURL(u => u.toString().includes('/launch/docs'), { timeout: 120000 });
  console.log('Authenticated. Waiting for Docsify to load...');
  await page.waitForTimeout(4000);

  // Get the inner docs frame (the <object> element)
  const frames = page.frames();
  const docsFrame = frames.find(f => f.url().includes('/docs/'));
  if (!docsFrame) {
    console.error('Could not find docs frame. Frames found:', frames.map(f => f.url()));
    await browser.close();
    return;
  }
  console.log('Found docs frame:', docsFrame.url());

  // Extract sidebar links from the Docsify frame
  await docsFrame.waitForLoadState('networkidle');
  const sidebarLinks = await docsFrame.$$eval('a[href]', els =>
    els.map(a => a.getAttribute('href')).filter(h => h && !h.startsWith('http') && !h.startsWith('mailto'))
  );
  console.log('\nSidebar links found:', sidebarLinks.length);

  // Click each sidebar link to trigger Docsify to fetch its markdown
  for (const link of sidebarLinks) {
    try {
      const el = await docsFrame.$(`a[href="${link}"]`);
      if (el) {
        await el.click();
        await docsFrame.waitForLoadState('networkidle');
        await docsFrame.waitForTimeout(800);
      }
    } catch (e) {
      // continue
    }
  }

  console.log('\nAll discovered markdown paths:');
  for (const p of mdPaths) console.log(' ', p);

  // Now fetch all markdown files using authenticated request
  const apiContext = await context.request;
  console.log('\nDownloading markdown files...');
  let count = 0;
  for (const mdPath of mdPaths) {
    const url = `https://${HOST}${mdPath}`;
    try {
      const resp = await apiContext.get(url);
      if (resp.ok()) {
        const body = await resp.text();
        const localPath = path.join(OUT_DIR, mdPath.replace(/^\/docs\//, ''));
        fs.mkdirSync(path.dirname(localPath), { recursive: true });
        fs.writeFileSync(localPath, body, 'utf8');
        count++;
        console.log(`  saved: ${localPath}`);
      } else {
        console.warn(`  SKIP ${url} (${resp.status()})`);
      }
    } catch (e) {
      console.warn(`  ERROR ${url}: ${e.message}`);
    }
  }

  await browser.close();
  console.log(`\nDone. ${count} files saved to ${OUT_DIR}`);
})();
