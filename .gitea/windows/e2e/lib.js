// Helpers shared by the specs. Each spec gets a `t` object built here.
const { execFileSync } = require('child_process');

class Failure extends Error {}

function makeContext(page, { shotDir, vmHost, sshArgs, vmDir, log }) {
  const t = {
    page,
    log,
    // Call a Tauri command the way the frontend does.
    invoke: (cmd, args = {}) =>
      page.evaluate(([c, a]) => window.__TAURI_INTERNALS__.invoke(c, a), [cmd, args]),
    check(cond, what) {
      if (!cond) throw new Failure(what);
      log(`  ok: ${what}`);
    },
    // Poll fn() until it returns something truthy; fail with `what` after timeoutMs.
    async waitFor(what, fn, { timeoutMs = 60000, everyMs = 1500 } = {}) {
      const t0 = Date.now();
      for (;;) {
        const v = await fn();
        if (v) {
          log(`  ok: ${what} (${Math.round((Date.now() - t0) / 1000)} s)`);
          return v;
        }
        if (Date.now() - t0 > timeoutMs) throw new Failure(`${what}: not within ${timeoutMs / 1000} s`);
        await page.waitForTimeout(everyMs);
      }
    },
    shot: (name) => page.screenshot({ path: `${shotDir}/${name}.png` }),
    // Run one of the vm/*.ps1 helpers on the VM and return its stdout.
    vm(script) {
      return execFileSync('ssh', [...sshArgs, vmHost,
        `powershell -NoProfile -ExecutionPolicy Bypass -File ${vmDir}\\${script}`], { encoding: 'utf8' });
    },
    // Which card runtime the specs use: "windows" (cmd.exe) or "wsl" (tmux in WSL).
    runtime: process.env.RUNTIME || 'windows',
    drawerClaudes() {
      const out = t.vm('drawer-claudes.ps1').trim();
      return out ? JSON.parse(out) : [];
    },
    // Claude Code processes running inside the card tmux sessions in WSL.
    wslState() {
      const out = t.vm('wsl-state.ps1').trim();
      return out ? JSON.parse(out) : { sessions: [], claudes: [] };
    },
    // The card's Claude processes for the current runtime, as [{ pid }].
    claudes() {
      return t.runtime === 'wsl' ? t.wslState().claudes : t.drawerClaudes();
    },
    async card(name) {
      const st = await t.invoke('get_board_state');
      return st.cards.find((c) => c.link.name === name);
    },
    // Cards in the test project. The app also discovers the VM's other
    // Claude sessions, so the whole board is never just the test's cards.
    async cards() {
      const norm = (p) => (p || '').replace(/\\/g, '/').toLowerCase();
      return (await t.invoke('get_board_state')).cards
        .filter((c) => norm(c.link.projectPath) === 'c:/users/dev/code/kc-e2e');
    },
    // Visible text of the embedded terminal.
    termText: () => page.evaluate(() =>
      [...document.querySelectorAll('.xterm-rows > div')].map((d) => d.textContent.replace(/\s+$/, '')).join('\n')),
    async termType(text, { enter = true } = {}) {
      await page.locator('.xterm-helper-textarea').first().focus();
      await page.keyboard.type(text, { delay: 15 });
      if (enter) {
        await page.waitForTimeout(400);
        await page.keyboard.press('Enter');
      }
    },
    // Text of the drawer's History tab (its scrolling pane on the right).
    historyText: () => page.evaluate(() => [...document.querySelectorAll('*')].filter((e) => {
      const s = getComputedStyle(e), r = e.getBoundingClientRect();
      return /(auto|scroll)/.test(s.overflowY) && r.x > 600 && r.height > 150;
    }).map((e) => e.innerText).join('\n')),
    tab: (name) => page.getByText(name, { exact: true }).first().click(),
    async closeDrawer() {
      await page.keyboard.press('Escape');
      await page.mouse.click(5, 770);
      await page.waitForTimeout(500);
    },
    // innerText of the board column with this heading.
    columnText: (name) => page.evaluate((n) => {
      const heads = [...document.querySelectorAll('*')].filter((e) => e.childElementCount === 0 && e.textContent.trim() === n);
      for (const h of heads) {
        let el = h;
        for (let i = 0; i < 8 && el; i++, el = el.parentElement) {
          const r = el.getBoundingClientRect();
          if (r.height > 400 && r.width > 120 && r.width < 400) return el.innerText;
        }
      }
      return null;
    }, name),
  };
  return t;
}

module.exports = { makeContext, Failure };
