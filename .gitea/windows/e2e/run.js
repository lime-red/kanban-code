// Run the specs in specs/ in name order against the app on the VM.
//
//   node run.js <shot dir> [spec name filter]
//
// Connects to WebView2's debug port at 127.0.0.1:9222 (run-windows-test.sh
// tunnels it from the VM). Specs build on each other (one card, one Claude
// session), so the first failure skips the rest. Exit 0 if all pass.
// Environment: VM_HOST, VM_SSH_KEY, VM_DIR (set by run-windows-test.sh).
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');
const { makeContext, Failure } = require('./lib');

(async () => {
  const [shotDir, filter] = process.argv.slice(2);
  fs.mkdirSync(shotDir, { recursive: true });
  const specs = fs.readdirSync(path.join(__dirname, 'specs'))
    .filter((f) => f.endsWith('.js') && (!filter || f.includes(filter)))
    .sort();

  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  const page = browser.contexts()[0].pages()[0];
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') console.log(`  [page error] ${m.text()}`); });
  // The app can still be loading its first board when the port answers.
  await page.waitForFunction(() => window.__TAURI_INTERNALS__, null, { timeout: 60000 });

  const t = makeContext(page, {
    shotDir,
    vmHost: process.env.VM_HOST,
    sshArgs: ['-i', process.env.VM_SSH_KEY, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes'],
    vmDir: process.env.VM_DIR,
    log: (...a) => console.log(...a),
  });

  const results = [];
  let failed = false;
  for (const file of specs) {
    const name = file.replace(/\.js$/, '');
    if (failed) { results.push([name, 'skipped']); continue; }
    const spec = require(path.join(__dirname, 'specs', file));
    console.log(`\n== ${name}: ${spec.title}`);
    const t0 = Date.now();
    try {
      await spec.run(t);
      results.push([name, `pass (${Math.round((Date.now() - t0) / 1000)} s)`]);
    } catch (e) {
      failed = true;
      results.push([name, `FAIL: ${e.message}`]);
      console.log(`  FAIL: ${e instanceof Failure ? e.message : e.stack}`);
      await t.shot(`${name}-failed`).catch(() => {});
    }
  }
  if (pageErrors.length) {
    failed = true;
    results.push(['page exceptions', `FAIL: ${pageErrors.join(' | ')}`]);
  }
  await browser.close(); // disconnects; the app keeps running

  console.log('\n== Summary');
  for (const [n, r] of results) console.log(`  ${n.padEnd(28)} ${r}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(`run.js: ${e.stack}`); process.exit(2); });
