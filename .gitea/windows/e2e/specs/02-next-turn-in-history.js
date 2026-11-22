// A turn sent from the terminal shows up in the open History tab (#26).
module.exports = {
  title: 'a new turn appears in the open History tab',
  async run(t) {
    await t.tab('Terminal');
    await t.page.waitForTimeout(1500);
    await t.termType('Reply with only the word e2e-second and nothing else.');
    await t.page.waitForTimeout(800);
    await t.tab('History');
    await t.waitFor('History shows the second reply', async () => /^\s*e2e-second\s*$/m.test(await t.historyText()),
      { timeoutMs: 90000, everyMs: 3000 });
  },
};
