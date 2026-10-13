// The banner (501x146) is at the top of every screen: the grant screen of each mode and the ticket screen.
import { describe, expect, test } from 'vitest';
import { routes as formRoutes } from '../src/modes/form/index.ts';
import { routes as inlineRoutes } from '../src/modes/inline/index.ts';
import { routes as pageRoutes } from '../src/modes/page/index.ts';
import { CODE, mountAt, SIG } from './helpers.ts';

describe.each([
  ['page: grant screen', pageRoutes, '/'],
  ['page: ticket screen', pageRoutes, `/tickets/${CODE}?sig=${SIG}`],
  ['inline: grant screen', inlineRoutes, '/'],
  ['form: grant screen', formRoutes, '/'],
])('%s', (_name, routes, path) => {
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
