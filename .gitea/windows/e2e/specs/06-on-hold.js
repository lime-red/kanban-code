// The hold menu: a preset shows its date on the card at once (#28), and the
// date picker holds until local midnight of the picked day (#29).
module.exports = {
  title: 'hold presets show the date at once; the date picker holds to a day',
  async run(t) {
    const near = (text) => {
      const flat = (text || '').replace(/\s+/g, ' ');
      const i = flat.indexOf('E2E card');
      return i < 0 ? null : flat.slice(i, i + 120);
    };
    // Right-click until the menu is up: a board refresh re-rendering the card
    // (just after it moved column) can swallow the first right-click.
    const menu = async () => {
      const dateInput = t.page.getByLabel('Hold until date');
      for (let i = 0; i < 4; i++) {
        await t.page.getByText('E2E card', { exact: true }).first().click({ button: 'right' });
        if (await dateInput.waitFor({ timeout: 2500 }).then(() => true, () => false)) return;
        await t.page.keyboard.press('Escape');
      }
      throw new Error('the card menu did not open after 4 right-clicks');
    };

    await menu();
    for (const label of ['Hold until tomorrow', 'Hold for 3 days', 'Hold for 1 week']) {
      t.check(await t.page.getByText(label, { exact: true }).count() > 0, `menu offers "${label}"`);
    }
    await t.page.getByText('Hold for 3 days', { exact: true }).first().click();
    await t.waitFor('On Hold card shows its date', async () => /Until/.test(near(await t.columnText('On Hold')) || ''),
      { timeoutMs: 2000, everyMs: 150 });

    // Ten days ahead, as the date input wants it (local time, YYYY-MM-DD).
    const pick = await t.page.evaluate(() => {
      const d = new Date();
      d.setDate(d.getDate() + 10);
      return { value: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`, day: d.getDate() };
    });
    await menu();
    await t.page.getByLabel('Hold until date').fill(pick.value);
    const stored = await t.waitFor(`card held until ${pick.value}`, async () => {
      const until = (await t.card('E2E card')).link.onHoldUntil;
      return until && t.page.evaluate(([u, day]) => {
        const d = new Date(u);
        return d.getDate() === day && d.getHours() === 0 && d.getMinutes() === 0 && u;
      }, [until, pick.day]);
    }, { timeoutMs: 15000, everyMs: 500 });
    t.log(`  stored onHoldUntil ${stored}`);
    // A refresh already running when the date was set can show its older
    // snapshot for a few seconds before the next one corrects it (#33).
    await t.waitFor('badge shows the picked day', async () => new RegExp(`Until ${pick.day}\\b`).test(near(await t.columnText('On Hold')) || ''),
      { timeoutMs: 15000, everyMs: 500 });
  },
};
