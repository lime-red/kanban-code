// /clear in the card's terminal moves the card to the new session instead of
// making a second card (#9), and History shows the command cleanly rather
// than Claude Code's metadata tags (#27).
module.exports = {
  title: '/clear keeps the session on its card; History hides metadata',
  async run(t) {
    const before = (await t.card('E2E card')).link.sessionLink.sessionId;
    await t.tab('Terminal');
    await t.page.waitForTimeout(1000);
    await t.termType('/clear', { enter: false });
    await t.page.waitForTimeout(1500);
    await t.page.keyboard.press('Enter');
    await t.page.waitForTimeout(4000);
    await t.termType('Reply with only the word e2e-afterclear and nothing else.');

    await t.waitFor('card moves to the new session', async () => {
      const sid = (await t.card('E2E card')).link.sessionLink?.sessionId;
      return sid && sid !== before;
    }, { timeoutMs: 90000, everyMs: 3000 });
    const cards = await t.cards();
    t.check(cards.length === 1, `still one card in the test project (found ${cards.length})`);

    await t.tab('History');
    const history = await t.waitFor('History shows the reply after /clear',
      async () => { const h = await t.historyText(); return /e2e-afterclear/.test(h) && h; },
      { timeoutMs: 90000, everyMs: 3000 });
    t.check(!/local-command|command-name|command-message/.test(history), 'no metadata tags in History');
    t.check(/\/clear/.test(history), 'History shows the /clear command');
    const board = await t.page.evaluate(() => document.body.innerText);
    t.check(!/local-command-caveat/.test(board), 'no caveat text anywhere on the board');
  },
};
