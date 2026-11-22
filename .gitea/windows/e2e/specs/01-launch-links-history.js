// A new task launched from the drawer links its session, and History fills
// in while the drawer stays open (#26).
module.exports = {
  title: 'launch from the drawer; History fills without reopening',
  async run(t) {
    const project = 'C:\\Users\\dev\\code\\kc-e2e';
    // On fresh data the first refresh discovers every session on the VM and
    // takes a while; a card created meanwhile is lost when that refresh writes
    // the board back (#33). Wait for two identical board reads first.
    let last = null;
    await t.waitFor('board settles after the first refresh', async () => {
      const ids = (await t.invoke('get_board_state')).cards.map((c) => c.id).sort().join();
      const settled = ids && ids === last;
      last = ids;
      return settled;
    }, { timeoutMs: 90000, everyMs: 4000 });
    const link = await t.invoke('create_card', {
      prompt: 'Reply with exactly three lines: e2e-one, e2e-two, e2e-three. Do not use any tools.',
      title: 'E2E card',
      project,
      launch: false,
    });
    await t.invoke('set_card_runtime', { cardId: link.id, runtime: 'windows' });
    // Still there a few seconds on, i.e. not overwritten by a refresh (#33).
    await t.page.waitForTimeout(5000);
    const names = (await t.cards()).map((c) => c.link.name);
    t.check(names.length === 1 && names[0] === 'E2E card',
      `the test project holds just the test card (found: ${JSON.stringify(names)})`);

    const title = t.page.getByText('E2E card', { exact: true }).first();
    await title.waitFor({ timeout: 20000 });
    await title.click();
    const launch = t.page.getByRole('button', { name: 'Launch', exact: true });
    await launch.first().waitFor({ timeout: 20000 });
    await launch.first().click();

    const historyTab = t.page.getByText('History', { exact: true });
    await t.waitFor('History tab appears', async () => (await historyTab.count()) > 0, { timeoutMs: 90000 });
    await t.tab('History');
    await t.waitFor('card links its session', async () => (await t.card('E2E card')).link.sessionLink?.sessionId,
      { timeoutMs: 90000 });
    await t.waitFor('History shows the reply', async () => /e2e-three/.test(await t.historyText()),
      { timeoutMs: 90000 });
  },
};
