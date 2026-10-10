// 画面遷移方式（src/modes/page/）: API、発行画面、SPA のチケット画面。
import { flushPromises } from '@vue/test-utils';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { grantForPage, qrUrl, TicketRouteSchema } from '../../src/modes/page/api.ts';
import { routes } from '../../src/modes/page/index.ts';
import { API, choosePhoto, CODE, json, mountAt, photo, SIG, stubFetch } from '../helpers.ts';

afterEach(() => vi.unstubAllGlobals());

const pageTicket = {
  ticketCode: CODE,
  issuedAt: '2026-10-05T13:50:54+09:00',
  sig: SIG,
  qrUrl: `${API}/v1/tickets/${CODE}/qr?sig=${SIG}`,
};

describe('API', () => {
  test('grantForPage posts to the ticket grant API with Accept: application/json', async () => {
    const fetch = stubFetch(json(201, pageTicket));
    expect(await grantForPage(API, photo())).toEqual(pageTicket);
    const [url, init] = fetch.mock.calls[0]!;
    expect(url).toBe(`${API}/v1/tickets`);
    expect(new Headers(init?.headers).get('Accept')).toBe('application/json');
  });

  test('a 201 with a malformed sig is UNEXPECTED', async () => {
    stubFetch(json(201, { ...pageTicket, sig: 'short' }));
    await expect(grantForPage(API, photo())).rejects.toMatchObject({ code: 'UNEXPECTED' });
  });

  test('qrUrl builds the QR image API URL from the route parameters', () => {
    expect(qrUrl(API, CODE, 'a+b/c')).toBe(`${API}/v1/tickets/${CODE}/qr?sig=a%2Bb%2Fc`);
    expect(qrUrl('', CODE, SIG)).toBe(`/v1/tickets/${CODE}/qr?sig=${SIG}`);
  });

  test('the ticket screen URL needs a ticket code and a sig', () => {
    expect(TicketRouteSchema.safeParse({ code: CODE, sig: SIG }).success).toBe(true);
    expect(TicketRouteSchema.safeParse({ code: CODE }).success).toBe(false);
  });
});

describe('grant screen', () => {
  test('one grant button; no other mode on the screen', async () => {
    const { wrapper } = await mountAt(routes, '/');
    expect(wrapper.find('[data-testid="grant-page"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="grant-inline"]').exists()).toBe(false);
    expect(wrapper.find('[data-testid="post-form"]').exists()).toBe(false);
  });

  test('non-Android: one file input, no camera button', async () => {
    const { wrapper } = await mountAt(routes, '/');
    expect(wrapper.find('[data-testid="image-input"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="camera-input"]').exists()).toBe(false);
  });

  test('Android: "画像を選ぶ" and "カメラを起動" buttons; either one sets the image', async () => {
    vi.stubGlobal('navigator', {
      ...navigator,
      userAgent: 'Mozilla/5.0 (Linux; Android 10; K) Chrome/140.0.0.0 Mobile',
    });
    const { wrapper } = await mountAt(routes, '/');
    const buttons = wrapper.get('[data-testid="image-buttons"]');
    expect(buttons.text()).toContain('画像を選ぶ');
    expect(buttons.text()).toContain('カメラを起動');
    const camera = wrapper.get('[data-testid="camera-input"]');
    expect(camera.attributes('capture')).toBe('environment');
    expect(wrapper.get('[data-testid="image-input"]').attributes('capture')).toBeUndefined();

    Object.defineProperty(camera.element, 'files', { value: [photo('camera.jpg', 'image/jpeg')], configurable: true });
    await camera.trigger('change');
    expect(wrapper.get('[data-testid="image-info"]').text()).toContain('camera.jpg');
    expect(wrapper.get('[data-testid="grant-page"]').attributes('disabled')).toBeUndefined();
  });

  test('the button is disabled until a usable photo is chosen', async () => {
    const { wrapper } = await mountAt(routes, '/');
    const button = wrapper.get('[data-testid="grant-page"]');
    expect(button.attributes('disabled')).toBeDefined();
    await choosePhoto(wrapper, photo('a.pdf', 'application/pdf'));
    expect(wrapper.get('[data-testid="image-problem"]').text()).toContain('対応していません');
    expect(button.attributes('disabled')).toBeDefined();
    await choosePhoto(wrapper);
    expect(button.attributes('disabled')).toBeUndefined();
  });

  test('grants and moves to the ticket screen (replace)', async () => {
    stubFetch(json(201, pageTicket));
    const { wrapper, router } = await mountAt(routes, '/');
    const replace = vi.spyOn(router, 'replace');
    await choosePhoto(wrapper);
    await wrapper.get('[data-testid="grant-page"]').trigger('click');
    await flushPromises();
    expect(replace).toHaveBeenCalledWith({ path: `/tickets/${CODE}`, query: { sig: SIG } });
    expect(router.currentRoute.value.fullPath).toBe(`/tickets/${CODE}?sig=${SIG}`);
  });

  // REJECT and RETRY from the image analysis server come back as separate codes with separate messages.
  test.each([
    ['IMAGE_REJECTED', 'image was rejected', 'この証明書の画像ではチケットを発行できません'],
    [
      'IMAGE_RETRY',
      'image could not be verified; take it again',
      '画像をうまく確認できませんでした。明るい場所で、証明書全体が写るように撮り直してください',
    ],
  ])('an API error is shown: %s', async (code, message, shown) => {
    stubFetch(json(422, { error: { code, message } }));
    const { wrapper, router } = await mountAt(routes, '/');
    await choosePhoto(wrapper);
    await wrapper.get('[data-testid="grant-page"]').trigger('click');
    await flushPromises();
    expect(wrapper.get('[data-testid="error"]').text()).toBe(shown);
    expect(router.currentRoute.value.path).toBe('/');
  });
});

describe('ticket screen (drawn from the URL only)', () => {
  test('shows the QR from the QR image API, the code and the granted time (issuedAt) from the code', async () => {
    const fetch = stubFetch();
    const { wrapper } = await mountAt(routes, `/tickets/${CODE}?sig=${SIG}`);
    expect(wrapper.get('img').attributes('src')).toBe(`${API}/v1/tickets/${CODE}/qr?sig=${SIG}`);
    expect(wrapper.get('[data-testid="ticket-code"]').text()).toBe(CODE);
    expect(wrapper.get('[data-testid="issued-at"]').text()).toBe('発行: 2026-10-05 13:50:54');
    expect(fetch).not.toHaveBeenCalled(); // no re-grant on reload
  });

  test.each([
    ['missing sig', `/tickets/${CODE}`],
    ['malformed sig', `/tickets/${CODE}?sig=short`],
    ['malformed code', `/tickets/not-a-code?sig=${SIG}`],
  ])('%s: invalid URL message without calling the API', async (_name, path) => {
    const { wrapper } = await mountAt(routes, path);
    expect(wrapper.get('[data-testid="error"]').text()).toBe('無効なチケット URL です');
    expect(wrapper.find('img').exists()).toBe(false);
  });

  test('a QR that fails to load (403 for a wrong sig) shows the invalid URL message', async () => {
    const { wrapper } = await mountAt(routes, `/tickets/${CODE}?sig=${SIG}`);
    await wrapper.get('img').trigger('error');
    expect(wrapper.get('[data-testid="error"]').text()).toBe('無効なチケット URL です');
  });
});
