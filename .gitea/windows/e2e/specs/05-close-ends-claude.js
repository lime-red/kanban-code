// Closing the drawer.
//   windows: ends the terminal's whole process tree, Claude Code included
//            (#30: only cmd.exe used to die, leaving claude.exe running).
//   wsl:     Claude keeps running in the card's tmux session (#31), and
//            reopening the card reattaches to that same Claude.
module.exports = {
  title: 'closing the drawer: ends Claude (windows) or keeps it in tmux (wsl)',
  async run(t) {
    const before = t.claudes();
    t.check(before.length === 1, 'Claude running before close');
    await t.closeDrawer();

    if (t.runtime !== 'wsl') {
      await t.waitFor('no Claude left under a drawer terminal', async () => t.drawerClaudes().length === 0,
        { timeoutMs: 20000, everyMs: 2000 });
      return;
    }

    await t.page.waitForTimeout(5000);
    const after = t.claudes();
    t.check(after.length === 1 && after[0].pid === before[0].pid,
      `Claude still running in tmux after close (${before[0].pid} -> ${after.map((p) => p.pid).join(',') || 'none'})`);

    await t.page.getByText('E2E card', { exact: true }).first().click();
    await t.waitFor('terminal reattaches on reopen', async () => {
      const rows = await t.page.evaluate(() =>
        [...document.querySelectorAll('.xterm-rows > div')].map((d) => d.textContent).join('\n'));
      return /e2e-afterclear/.test(rows);
    }, { timeoutMs: 30000, everyMs: 2000 });
    const reopened = t.claudes();
    t.check(reopened.length === 1 && reopened[0].pid === before[0].pid,
      `same Claude after reopening (${reopened.map((p) => p.pid).join(',') || 'none'})`);
    await t.closeDrawer();
  },
};
