// The notes come after the grant button and the error box on the grant screen of every mode. Their wording may be
// replaced later, so only their presence and place are checked, not the text.
import { describe, expect, test } from 'vitest';
import { choosePhoto, MODES, mountAt, photo } from './helpers.ts';

// The grant button of each mode. The form mode has no error box (its errors are on the API's pages).
const BUTTON = { page: 'data-testid="grant-page"', inline: 'data-testid="grant-inline"', form: 'type="submit"' };

describe.each(MODES.map(({ mode, routes }) => [mode, routes] as const))('%s: grant screen', (mode, routes) => {
  test('shows the notes after the button (and the error box)', async () => {
    const { wrapper } = await mountAt(routes, '/');
    if (mode !== 'form') await choosePhoto(wrapper, photo('a.pdf', 'application/pdf')); // shows the error box
    const items = wrapper.get('[data-testid="grant-notes"]').findAll('li');
    expect(items.length).toBeGreaterThan(0);
    for (const item of items) expect(item.text().trim()).not.toBe('');
    const html = wrapper.html();
    const at = (s: string) => html.indexOf(s);
    expect(at(BUTTON[mode])).toBeGreaterThan(-1);
    expect(at(BUTTON[mode])).toBeLessThan(at('data-testid="grant-notes"'));
    if (mode !== 'form') {
      expect(at(BUTTON[mode])).toBeLessThan(at('data-testid="error"'));
      expect(at('data-testid="error"')).toBeLessThan(at('data-testid="grant-notes"'));
    }
  });
});
