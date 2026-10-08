import { afterEach, describe, expect, test, vi } from 'vitest';
import { ApiError, grantForPage, grantInline, qrUrl, TicketRouteSchema } from '../src/api/tickets.ts';
import { API, CODE, json, photo, SIG, stubFetch } from './helpers.ts';

afterEach(() => vi.unstubAllGlobals());

const pageTicket = {
  ticketCode: CODE,
  issuedAt: '2026-10-05T13:50:54+09:00',
  sig: SIG,
  qrUrl: `${API}/v1/tickets/${CODE}/qr?sig=${SIG}`,
};

describe('grantForPage (ticket grant API, JSON)', () => {
  test('posts the photo as-is with Accept: application/json and returns the signed ticket', async () => {
    const fetch = stubFetch(json(201, pageTicket));
    const file = photo();
    expect(await grantForPage(API, file)).toEqual(pageTicket);

    const [url, init] = fetch.mock.calls[0]!;
    expect(url).toBe(`${API}/v1/tickets`);
    expect(init?.method).toBe('POST');
    expect(new Headers(init?.headers).get('Accept')).toBe('application/json');
    expect((init?.body as FormData).get('image')).toBe(file);
  });

  test('API errors become ApiError with the code and status', async () => {
    stubFetch(json(422, { error: { code: 'IMAGE_RETRY', message: 'image could not be verified; take it again' } }));
    await expect(grantForPage(API, photo())).rejects.toMatchObject({ code: 'IMAGE_RETRY', status: 422 });
  });

  test('a 201 of the wrong shape is UNEXPECTED', async () => {
    stubFetch(json(201, { ...pageTicket, sig: 'short' }));
    await expect(grantForPage(API, photo())).rejects.toMatchObject({ code: 'UNEXPECTED' });
  });

  test('a non-JSON error (e.g. a proxy page) is UNEXPECTED', async () => {
    stubFetch(new Response('<html>Bad Gateway</html>', { status: 502 }));
    await expect(grantForPage(API, photo())).rejects.toMatchObject({ code: 'UNEXPECTED', status: 502 });
  });

  test('network failures and timeouts are NETWORK', async () => {
    stubFetch(new TypeError('Failed to fetch'));
    const err = await grantForPage(API, photo()).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({ code: 'NETWORK' });
  });
});

describe('grantInline (QR inline grant API)', () => {
  test('returns the QR as base64 and sends no Accept header', async () => {
    const body = {
      ticketCode: CODE,
      issuedAt: '2026-10-05T13:50:54+09:00',
      qr: { mimeType: 'image/png', data: 'iVBORw0KGgo=' },
    };
    const fetch = stubFetch(json(201, body));
    expect(await grantInline(API, photo())).toEqual(body);
    expect(fetch.mock.calls[0]![0]).toBe(`${API}/v1/tickets/qr-inline`);
    expect(new Headers(fetch.mock.calls[0]![1]?.headers).has('Accept')).toBe(false);
  });
});

test('qrUrl builds the QR image API URL from the route parameters', () => {
  expect(qrUrl(API, CODE, 'a+b/c')).toBe(`${API}/v1/tickets/${CODE}/qr?sig=a%2Bb%2Fc`);
  expect(qrUrl('', CODE, SIG)).toBe(`/v1/tickets/${CODE}/qr?sig=${SIG}`);
});

describe('ticket code format', () => {
  // {YYYYMMDDHHmmss}{UUIDv4, 32 lowercase hex}{fixed suffix, 1-32 letters or digits}
  test.each([
    ['202610051350543f2b9c1e8a4d4f6b8e0c7a1d2b3c4d5eTQR', true],
    ['202610051350543f2b9c1e8a4d4f6b8e0c7a1d2b3c4d5eSTAGEFIXEDSUFFIX0123456789abcdef', true],
    ['202610051350543f2b9c1e8a4d4f6b8e0c7a1d2b3c4d5e', false], // no suffix
    ['202610051350543F2B9C1E8A4D4F6B8E0C7A1D2B3C4D5ETQR', false], // uppercase UUID
    ['20261005135054-3f2b9c1e-8a4d-4f6b-8e0c-7a1d2b3c4d5eTQR', false], // hyphens
    ['20261005135054-4BV81K5V', false], // the former format
  ])('%s → %s', (code, ok) => {
    expect(TicketRouteSchema.safeParse({ code, sig: SIG }).success).toBe(ok);
  });
});
