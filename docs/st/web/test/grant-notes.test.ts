// The notes come after the grant button and the error box on the grant screen of every mode. Their wording may be
// replaced later, so only their presence and place are checked, not the text.
import { describe, expect, test } from 'vitest';
import { routes as formRoutes } from '../src/modes/form/index.ts';
import { routes as inlineRoutes } from '../src/modes/inline/index.ts';
import { routes as pageRoutes } from '../src/modes/page/index.ts';
import { choosePhoto, mountAt, photo } from './helpers.ts';

function notesOf(wrapper: Awaited<ReturnType<typeof mountAt>>['wrapper']) {
  const items = wrapper.get('[data-testid="grant-notes"]').findAll('li');
  expect(items.length).toBeGreaterThan(0);
  for (const item of items) expect(item.text().trim()).not.toBe('');
}

describe.each([
  ['page', pageRoutes, 'grant-page'],
  ['inline', inlineRoutes, 'grant-inline'],
])('%s: grant screen', (_mode, routes, button) => {
  test('shows the notes after the button and the error box', async () => {
    const { wrapper } = await mountAt(routes, '/');
    await choosePhoto(wrapper, photo('a.pdf', 'application/pdf')); // an unsupported format shows the error box
    notesOf(wrapper);
    const html = wrapper.html();
    const at = (s: string) => html.indexOf(s);
    expect(at('data-testid="error"')).toBeGreaterThan(-1);
    expect(at(`data-testid="${button}"`)).toBeLessThan(at('data-testid="error"'));
    expect(at('data-testid="error"')).toBeLessThan(at('data-testid="grant-notes"'));
  });
});

describe('form: grant screen', () => {
  test('shows the notes after the form (no error box in this mode)', async () => {
    const { wrapper } = await mountAt(formRoutes, '/');
    notesOf(wrapper);
    const html = wrapper.html();
    expect(html.indexOf('type="submit"')).toBeLessThan(html.indexOf('data-testid="grant-notes"'));
  });
});
