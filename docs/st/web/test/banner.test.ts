// The banner (501x146) is at the top of every screen: the grant screen of each mode and the ticket screen.
import { describe, expect, test } from 'vitest';
import { CODE, MODES, mountAt, SIG } from './helpers.ts';

describe.each(
  MODES.flatMap(({ mode, routes }) => [
    [`${mode}: grant screen`, routes, '/'] as const,
    ...(mode === 'page' ? [['page: ticket screen', routes, `/tickets/${CODE}?sig=${SIG}`] as const] : []),
  ]),
)('%s', (_name, routes, path) => {
  test('starts with the banner image at its real size', async () => {
    const { wrapper } = await mountAt(routes, path);
    const banner = wrapper.get('[data-testid="banner"]');
    const img = banner.get('img');
    expect([img.attributes('width'), img.attributes('height')]).toEqual(['501', '146']);
    expect(img.attributes('src')).toMatch(/banner.*\.png$/);
    expect(img.attributes('alt')).toBeTruthy();
    // The banner comes before the screen's own content.
    const html = wrapper.html();
    expect(html.indexOf('data-testid="banner"')).toBeLessThan(html.indexOf('<main'));
  });
});
