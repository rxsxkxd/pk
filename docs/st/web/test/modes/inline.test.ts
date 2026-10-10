// その場表示方式（src/modes/inline/）: API と、発行画面の中の QR の表示。
import { flushPromises } from '@vue/test-utils';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { grantInline } from '../../src/modes/inline/api.ts';
import { routes } from '../../src/modes/inline/index.ts';
import { API, choosePhoto, CODE, json, mountAt, photo, stubFetch } from '../helpers.ts';

afterEach(() => vi.unstubAllGlobals());

const inlineTicket = {
  ticketCode: CODE,
  issuedAt: '2026-10-05T13:50:54+09:00',
  qr: { mimeType: 'image/png', data: 'iVBORw0KGgo=' },
};

test('grantInline posts to the QR inline grant API without an Accept header and returns the QR as base64', async () => {
  const fetch = stubFetch(json(201, inlineTicket));
  expect(await grantInline(API, photo())).toEqual(inlineTicket);
  expect(fetch.mock.calls[0]![0]).toBe(`${API}/v1/tickets/qr-inline`);
  expect(new Headers(fetch.mock.calls[0]![1]?.headers).has('Accept')).toBe(false);
});

describe('grant screen', () => {
  test('one grant button; no other mode on the screen and no ticket screen route', async () => {
    const { wrapper, router } = await mountAt(routes, '/');
    expect(wrapper.find('[data-testid="grant-inline"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="grant-page"]').exists()).toBe(false);
    expect(wrapper.find('[data-testid="post-form"]').exists()).toBe(false);
    await router.push(`/tickets/${CODE}`);
    expect(router.currentRoute.value.path).toBe('/');
  });

  test('shows the QR in place', async () => {
    stubFetch(json(201, inlineTicket));
    const { wrapper } = await mountAt(routes, '/');
    await choosePhoto(wrapper);
    await wrapper.get('[data-testid="grant-inline"]').trigger('click');
    await flushPromises();
    const result = wrapper.get('[data-testid="inline-result"]');
    expect(result.get('img').attributes('src')).toBe('data:image/png;base64,iVBORw0KGgo=');
    expect(result.get('[data-testid="ticket-code"]').text()).toBe(CODE);
    expect(result.get('[data-testid="issued-at"]').text()).toBe('発行: 2026-10-05 13:50:54');
  });

  test('a failed retry clears the previous QR and shows the message', async () => {
    stubFetch(json(201, inlineTicket), json(422, { error: { code: 'IMAGE_REJECTED', message: 'image was rejected' } }));
    const { wrapper } = await mountAt(routes, '/');
    await choosePhoto(wrapper);
    await wrapper.get('[data-testid="grant-inline"]').trigger('click');
    await flushPromises();
    await wrapper.get('[data-testid="grant-inline"]').trigger('click');
    await flushPromises();
    expect(wrapper.find('[data-testid="inline-result"]').exists()).toBe(false);
    expect(wrapper.get('[data-testid="error"]').text()).toBe('この証明書の画像ではチケットを発行できません');
  });
});
