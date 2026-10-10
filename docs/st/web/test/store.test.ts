import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { ApiError } from '../src/api/client.ts';
import { MAX_IMAGE_BYTES } from '../src/config.ts';
import { checkFile, messageFor, sizeLabel, useTicketStore } from '../src/stores/ticket.ts';
import { API, config, photo, setupStore } from './helpers.ts';

beforeEach(() => setupStore());
afterEach(() => vi.unstubAllGlobals());

describe('checkFile (before sending)', () => {
  test.each([
    ['nothing chosen', null, '証明書の画像を選んでください'],
    ['over 4MB', photo('a.jpg', 'image/jpeg', MAX_IMAGE_BYTES + 1), '画像のサイズが大きすぎます（4MB まで）'],
    [
      'a PDF',
      photo('a.pdf', 'application/pdf'),
      'この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）',
    ],
  ])('%s', (_name, file, message) => {
    expect(checkFile(file)).toBe(message);
  });

  test.each([
    ['iPhone HEIC', photo('IMG_0001.HEIC', 'image/heic')],
    ['HEIC without a MIME type (some browsers)', photo('IMG_0001.heic', '')],
    ['Android JPEG', photo('PXL_0001.jpg', 'image/jpeg')],
    ['exactly 4MB', photo('a.webp', 'image/webp', MAX_IMAGE_BYTES)],
  ])('%s is fine', (_name, file) => {
    expect(checkFile(file)).toBeUndefined();
  });
});

describe('upload limit of the environment (config.json maxImageBytes)', () => {
  test('a lowered limit is checked and shown', () => {
    expect(checkFile(photo('a.jpg', 'image/jpeg', (1 << 20) + 1), 1 << 20)).toBe(
      '画像のサイズが大きすぎます（1MB まで）',
    );
    expect(checkFile(photo('a.jpg', 'image/jpeg', 1 << 20), 1 << 20)).toBeUndefined();
    expect(messageFor(new ApiError('PAYLOAD_TOO_LARGE', ''), 3 << 19)).toBe('画像のサイズが大きすぎます（1.5MB まで）');
  });

  test.each([
    [4 << 20, '4MB'],
    [3 << 19, '1.5MB'],
    [5_000_000, '4.7MB'],
    [512 << 10, '512KB'],
  ])('sizeLabel(%i) = %s', (bytes, label) => {
    expect(sizeLabel(bytes)).toBe(label);
  });

  test('the store uses the limit in config.json', () => {
    const store = useTicketStore();
    store.file = photo('a.jpg', 'image/jpeg', 2 << 20);
    expect(store.fileProblem).toBeUndefined();
    setupStore({ ...config(), maxImageBytes: 1 << 20 });
    const limited = useTicketStore();
    limited.file = photo('a.jpg', 'image/jpeg', 2 << 20);
    expect(limited.fileProblem).toBe('画像のサイズが大きすぎます（1MB まで）');
  });
});

test.each([
  ['PAYLOAD_TOO_LARGE', '画像のサイズが大きすぎます（4MB まで）'],
  ['UNSUPPORTED_MEDIA_TYPE', 'この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）'],
  ['IMAGE_REJECTED', 'この証明書の画像ではチケットを発行できません'],
  ['IMAGE_RETRY', '画像をうまく確認できませんでした。明るい場所で、証明書全体が写るように撮り直してください'],
  ['ANALYSIS_UPSTREAM_ERROR', 'ただいま混み合っています。時間をおいてお試しください'],
  ['ANALYSIS_TIMEOUT', 'ただいま混み合っています。時間をおいてお試しください'],
  ['BAD_REQUEST', '発行できませんでした。もう一度お試しください'],
  ['NETWORK', '発行できませんでした。もう一度お試しください'],
])('message for %s', (code, message) => {
  expect(messageFor(new ApiError(code, ''))).toBe(message);
});

// send() is what every grant mode uses (src/modes/<mode>/); the request is the mode's API call.
describe('sending', () => {
  test('passes the API base URL and the chosen photo to the request and returns its result', async () => {
    const store = useTicketStore();
    const file = photo();
    store.file = file;
    const request = vi.fn(async () => 'granted ticket');
    expect(await store.send(request)).toBe('granted ticket');
    expect(request).toHaveBeenCalledWith(API, file);
    expect(store.status).toBe('granted');
    expect(store.error).toBeNull();
  });

  test('a failure shows the message and allows another try', async () => {
    const store = useTicketStore();
    store.file = photo();
    const request = async () => {
      throw new ApiError('ANALYSIS_TIMEOUT', 'image analysis timed out', 504);
    };
    expect(await store.send(request)).toBeUndefined();
    expect(store.status).toBe('failed');
    expect(store.error).toBe('ただいま混み合っています。時間をおいてお試しください');
    expect(store.canSend).toBe(true);
  });

  test('a second click while sending does not grant twice', async () => {
    let resolve!: (v: string) => void;
    const request = vi.fn(() => new Promise<string>((r) => (resolve = r)));
    const store = useTicketStore();
    store.file = photo();

    const first = store.send(request);
    expect(store.canSend).toBe(false);
    expect(await store.send(request)).toBeUndefined();
    resolve('granted ticket');
    expect(await first).toBe('granted ticket');
    expect(request).toHaveBeenCalledTimes(1);
  });

  test('nothing is sent when the file has a problem', async () => {
    const request = vi.fn(async () => 'granted ticket');
    const store = useTicketStore();
    store.file = photo('a.pdf', 'application/pdf');
    expect(await store.send(request)).toBeUndefined();
    expect(request).not.toHaveBeenCalled();
  });

  test('reset clears the photo, the status and the message', async () => {
    const store = useTicketStore();
    store.file = photo();
    await store.send(async () => {
      throw new ApiError('IMAGE_REJECTED', 'image was rejected', 422);
    });
    store.reset();
    expect([store.file, store.status, store.error]).toEqual([null, 'idle', null]);
  });
});
