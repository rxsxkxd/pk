// The shared API client (src/api/client.ts). Each mode's endpoints are tested in test/modes/.
import { afterEach, describe, expect, test, vi } from 'vitest';
import * as v from 'valibot';
import { ApiError, postImage, Sig, TicketCode, TIMEOUT_MS } from '../src/api/client.ts';
import { API, json, photo, SIG, stubFetch } from './helpers.ts';

afterEach(() => vi.unstubAllGlobals());

const Ok = v.object({ ok: v.literal(true) });

describe('postImage', () => {
  test('posts the photo as-is as the multipart "image" field, with the given headers', async () => {
    const fetch = stubFetch(json(201, { ok: true }));
    const file = photo();
    expect(await postImage(`${API}/v1/x`, file, Ok, { Accept: 'application/json' })).toEqual({ ok: true });

    const [url, init] = fetch.mock.calls[0]!;
    expect(url).toBe(`${API}/v1/x`);
    expect(init?.method).toBe('POST');
    expect(new Headers(init?.headers).get('Accept')).toBe('application/json');
    expect((init?.body as FormData).get('image')).toBe(file);
  });

  test('API errors become ApiError with the code and status', async () => {
    stubFetch(json(422, { error: { code: 'IMAGE_RETRY', message: 'image could not be verified; take it again' } }));
    await expect(postImage(API, photo(), Ok)).rejects.toMatchObject({ code: 'IMAGE_RETRY', status: 422 });
  });

  test('a 201 of the wrong shape is UNEXPECTED', async () => {
    stubFetch(json(201, { ok: false }));
    await expect(postImage(API, photo(), Ok)).rejects.toMatchObject({ code: 'UNEXPECTED' });
  });

  test('a non-JSON error (e.g. a proxy page) is UNEXPECTED', async () => {
    stubFetch(new Response('<html>Bad Gateway</html>', { status: 502 }));
    await expect(postImage(API, photo(), Ok)).rejects.toMatchObject({ code: 'UNEXPECTED', status: 502 });
  });

  test('a request still unanswered after TIMEOUT_MS is aborted as NETWORK (no AbortSignal.timeout)', async () => {
    vi.useFakeTimers();
    try {
      const fetch = vi.fn(
        (_url: string, init?: RequestInit) =>
          new Promise<Response>((_resolve, reject) =>
            init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError'))),
          ),
      );
      vi.stubGlobal('fetch', fetch);
      const pending = postImage(API, photo(), Ok).catch((e: unknown) => e);
      await vi.advanceTimersByTimeAsync(TIMEOUT_MS);
      expect(await pending).toMatchObject({ code: 'NETWORK' });
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  test('the timer is cleared once the response is read', async () => {
    vi.useFakeTimers();
    try {
      stubFetch(json(201, { ok: true }));
      await postImage(API, photo(), Ok);
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  test('network failures and timeouts are NETWORK', async () => {
    stubFetch(new TypeError('Failed to fetch'));
    const err = await postImage(API, photo(), Ok).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({ code: 'NETWORK' });
  });
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
    expect(v.safeParse(TicketCode, code).success).toBe(ok);
  });

  test('sig is 22 base64url characters', () => {
    expect(v.safeParse(Sig, SIG).success).toBe(true);
    expect(v.safeParse(Sig, 'short').success).toBe(false);
  });
});
