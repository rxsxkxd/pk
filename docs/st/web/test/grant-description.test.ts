// The description sits between the heading and the image picker on the grant screen of every mode. Its wording
// may be replaced later, so only its presence and place are checked, not the text.
import { describe, expect, test } from 'vitest';
import { routes as formRoutes } from '../src/modes/form/index.ts';
import { routes as inlineRoutes } from '../src/modes/inline/index.ts';
import { routes as pageRoutes } from '../src/modes/page/index.ts';
import { mountAt } from './helpers.ts';

describe.each([
  ['page', pageRoutes],
  ['inline', inlineRoutes],
  ['form', formRoutes],
])('%s: grant screen', (_mode, routes) => {
  test('shows the description after the heading and before the file input', async () => {
    const { wrapper } = await mountAt(routes, '/');
    const description = wrapper.get('[data-testid="grant-description"]');
    expect(description.text().trim()).not.toBe('');
    const html = wrapper.html();
    const at = (s: string) => html.indexOf(s);
    expect(at('チケット発行')).toBeLessThan(at('data-testid="grant-description"'));
    expect(at('data-testid="grant-description"')).toBeLessThan(at('type="file"'));
  });
});
