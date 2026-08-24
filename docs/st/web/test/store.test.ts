import { flushPromises } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { ApiError } from '../src/api/client.ts';
import { MAX_IMAGE_BYTES } from '../src/config.ts';
import { shrinkToFit } from '../src/image/shrink.ts';
import { checkFile, messageFor, sizeLabel, useTicketStore } from '../src/stores/ticket.ts';
import { API, config, photo, setupStore } from './helpers.ts';

// The real compression needs a canvas (not in happy-dom); its steps are tested in shrink.test.ts.
vi.mock('../src/image/shrink.ts', () => ({ shrinkToFit: vi.fn() }));
const shrink = vi.mocked(shrinkToFit);

beforeEach(() => {
  setupStore();
  shrink.mockReset();
});
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
  });

  test.each([
    [4 << 20, '4MB'],
    [3 << 19, '1.5MB'],
    [5_000_000, '4.7MB'],
    [512 << 10, '512KB'],
  ])('sizeLabel(%i) = %s', (bytes, label) => {
    expect(sizeLabel(bytes)).toBe(label);
  });

  test('the store uses the limit in config.json (a photo that cannot be shrunk is too large)', async () => {
    shrink.mockResolvedValue(undefined);
    const store = useTicketStore();
    store.file = photo('a.jpg', 'image/jpeg', 2 << 20);
    expect(store.fileProblem).toBeUndefined();
    expect(shrink).not.toHaveBeenCalled();
    setupStore({ ...config(), maxImageBytes: 1 << 20 });
    const limited = useTicketStore();
    limited.file = photo('a.jpg', 'image/jpeg', 2 << 20);
    await flushPromises();
    expect(shrink).toHaveBeenCalledWith(limited.file, 1 << 20);
    expect(limited.fileProblem).toBe('画像のサイズが大きすぎます（1MB まで）');
  });
});

// notes/image-compression.md 7.1: only a photo over the limit is shrunk; one within it is sent as it is.
describe('shrinking a photo over the limit', () => {
  // A small limit keeps the dummy photos small (the tests compare File objects).
  const LIMIT = 4096;
  beforeEach(() => setupStore({ ...config(), maxImageBytes: LIMIT }));
  const big = () => photo('IMG_0001.jpg', 'image/jpeg', LIMIT + 1);
  const small = () => photo('IMG_0001.jpg', 'image/jpeg', 1024);

  test('a photo within the limit is sent as it is, without shrinking', async () => {
    const store = useTicketStore();
    const file = small();
    store.file = file;
    await flushPromises();
    expect(shrink).not.toHaveBeenCalled();
    const request = vi.fn(async () => 'ok');
    await store.send(request);
    expect(request).toHaveBeenCalledWith(API, file);
  });

  test('while shrinking nothing can be sent; then the shrunk photo is sent', async () => {
    let done!: (f: File) => void;
    shrink.mockReturnValue(new Promise((r) => (done = r)));
    const store = useTicketStore();
    store.file = big();
    expect([store.shrinking, store.canSend, store.fileProblem]).toEqual([true, false, undefined]);
    const request = vi.fn(async () => 'ok');
    expect(await store.send(request)).toBeUndefined();

    const shrunk = photo('IMG_0001.jpg', 'image/jpeg', 2048);
    done(shrunk);
    await flushPromises();
    expect([store.shrinking, store.canSend]).toEqual([false, true]);
    expect(store.shrunk).toBe(shrunk);
    await store.send(request);
    expect(request).toHaveBeenCalledWith(API, shrunk);
  });

  test('a photo that cannot be shrunk below the limit (or fails) is too large, as before', async () => {
    shrink.mockResolvedValue(undefined);
    const store = useTicketStore();
    store.file = big();
    await flushPromises();
    expect(store.shrinking).toBe(false);
    expect(store.fileProblem).toBe('画像のサイズが大きすぎます（4KB まで）');
    expect(store.canSend).toBe(false);
  });

  test('an unsupported format is not shrunk', async () => {
    const store = useTicketStore();
    store.file = photo('a.pdf', 'application/pdf', LIMIT + 1);
    await flushPromises();
    expect(shrink).not.toHaveBeenCalled();
  });

  test('choosing another photo while shrinking drops the old result', async () => {
    let done!: (f: File) => void;
    shrink.mockReturnValueOnce(new Promise((r) => (done = r)));
    const store = useTicketStore();
    store.file = big();
    const second = small();
    store.file = second;
    done(photo('old.jpg', 'image/jpeg', 1024));
    await flushPromises();
    expect(store.shrinking).toBe(false);
    expect(store.shrunk).toBeNull();
    const request = vi.fn(async () => 'ok');
    await store.send(request);
    expect(request).toHaveBeenCalledWith(API, second);
  });

  test('reset clears the shrunk photo', async () => {
    shrink.mockResolvedValue(photo('IMG_0001.jpg', 'image/jpeg', 1024));
    const store = useTicketStore();
    store.file = big();
    await flushPromises();
    store.reset();
    expect(store.file).toBeNull();
    expect(store.shrunk).toBeNull();
    expect(store.shrinking).toBe(false);
  });
});

test.each([
  ['PAYLOAD_TOO_LARGE', '画像のサイズが大きすぎます'], // no number: the API's limit is not known to the SPA
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
// One error box under the button: the chosen photo's problem first, otherwise the API's error.
describe('errorMessage (the error box under the button)', () => {
  const reject = async () => {
    throw new ApiError('IMAGE_REJECTED', 'image was rejected', 422);
  };

  test('nothing before a photo is chosen', () => {
    expect(useTicketStore().errorMessage).toBeUndefined();
  });

  test("the photo's problem (e.g. an unsupported format)", () => {
    const store = useTicketStore();
    store.file = photo('a.pdf', 'application/pdf');
    expect(store.errorMessage).toBe('この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）');
  });

  test("the API's error after sending", async () => {
    const store = useTicketStore();
    store.file = photo();
    await store.send(reject);
    expect(store.errorMessage).toBe('この証明書の画像ではチケットを発行できません');
  });

  test('choosing another photo clears the previous API error', async () => {
    const store = useTicketStore();
    store.file = photo();
    await store.send(reject);
    store.file = photo('b.jpg', 'image/jpeg');
    expect(store.errorMessage).toBeUndefined();
  });
});

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
