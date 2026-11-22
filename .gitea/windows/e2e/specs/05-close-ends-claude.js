// Closing the drawer ends the terminal's whole process tree, Claude Code
// included (#30: only cmd.exe used to die, leaving claude.exe running).
module.exports = {
  title: 'closing the drawer leaves no Claude running',
  async run(t) {
    t.check(t.drawerClaudes().length === 1, 'Claude running before close');
    await t.closeDrawer();
    await t.waitFor('no Claude left under a drawer terminal', async () => t.drawerClaudes().length === 0,
      { timeoutMs: 20000, everyMs: 2000 });
  },
};
