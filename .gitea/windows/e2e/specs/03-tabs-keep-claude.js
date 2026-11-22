// Switching to History and back keeps the terminal's Claude Code running and
// the terminal drawn (#30: the tab switch used to unmount the terminal).
module.exports = {
  title: 'tab switches keep the same Claude process',
  async run(t) {
    await t.tab('Terminal');
    await t.page.waitForTimeout(1500);
    const before = t.drawerClaudes();
    t.check(before.length === 1, `one Claude under the drawer terminal (found ${before.length})`);

    await t.tab('History');
    await t.page.waitForTimeout(3000);
    await t.tab('Terminal');
    await t.page.waitForTimeout(2000);
    const after = t.drawerClaudes();
    t.check(after.length === 1 && after[0].pid === before[0].pid,
      `same Claude pid after History and back (${before[0].pid} -> ${after.map((p) => p.pid).join(',') || 'none'})`);
    const rows = await t.page.evaluate(() => document.querySelector('.xterm-rows')?.children.length || 0);
    t.check(rows > 0, `terminal still drawn (${rows} rows)`);
  },
};
