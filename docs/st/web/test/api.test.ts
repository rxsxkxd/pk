import { afterEach, describe, expect, test, vi } from 'vitest';
import { ApiError, issueForPage, issueInline, qrUrl } from '../src/api/tickets.ts';
import { API, CODE, json, photo, SIG, stubFetch } from './helpers.ts';

afterEach(() => vi.unstubAllGlobals());

const pageTicket = {
  ticketCode: CODE,
  issuedAt: '2026-10-05T13:50:54+09:00',
  sig: SIG,
  qrUrl: `${API}/v1/tickets/${CODE}/qr?sig=${SIG}`,
};

describe('issueForPage (ticket issue API, JSON)', () => {
  test('posts the photo as-is with Accept: application/json and returns the signed ticket', async () => {
    const fetch = stubFetch(json(201, pageTicket));
    const file = photo();
    expect(await issueForPage(API, file)).toEqual(pageTicket);

    const [url, init] = fetch.mock.calls[0]!;
    expect(url).toBe(`${API}/v1/tickets`);
    expect(init?.method).toBe('POST');
    expect(new Headers(init?.headers).get('Accept')).toBe('application/json');
    expect((init?.body as FormData).get('image')).toBe(file);
  });

  test('API errors become ApiError with the code and status', async () => {
    stubFetch(json(422, { error: { code: 'IMAGE_INVALID', message: 'image was rejected' } }));
    await expect(issueForPage(API, photo())).rejects.toMatchObject({ code: 'IMAGE_INVALID', status: 422 });
  });

  test('a 201 of the wrong shape is UNEXPECTED', async () => {
    stubFetch(json(201, { ...pageTicket, sig: 'short' }));
    await expect(issueForPage(API, photo())).rejects.toMatchObject({ code: 'UNEXPECTED' });
  });

  test('a non-JSON error (e.g. a proxy page) is UNEXPECTED', async () => {
    stubFetch(new Response('<html>Bad Gateway</html>', { status: 502 }));
    await expect(issueForPage(API, photo())).rejects.toMatchObject({ code: 'UNEXPECTED', status: 502 });
  });

  test('network failures and timeouts are NETWORK', async () => {
    stubFetch(new TypeError('Failed to fetch'));
    const err = await issueForPage(API, photo()).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({ code: 'NETWORK' });
  });
});

describe('issueInline (QR inline issue API)', () => {
  test('returns the QR as base64 and sends no Accept header', async () => {
    const body = {
      ticketCode: CODE,
      issuedAt: '2026-10-05T13:50:54+09:00',
      qr: { mimeType: 'image/png', data: 'iVBORw0KGgo=' },
    };
    const fetch = stubFetch(json(201, body));
    expect(await issueInline(API, photo())).toEqual(body);
    expect(fetch.mock.calls[0]![0]).toBe(`${API}/v1/tickets/qr-inline`);
    expect(new Headers(fetch.mock.calls[0]![1]?.headers).has('Accept')).toBe(false);
  });
});

test('qrUrl builds the QR image API URL from the route parameters', () => {
  expect(qrUrl(API, CODE, 'a+b/c')).toBe(`${API}/v1/tickets/${CODE}/qr?sig=a%2Bb%2Fc`);
  expect(qrUrl('', CODE, SIG)).toBe(`/v1/tickets/${CODE}/qr?sig=${SIG}`);
});
