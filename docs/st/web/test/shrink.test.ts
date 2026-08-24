// src/image/shrink.ts: the steps tried until the photo fits (the compression itself is replaced).
import { describe, expect, test, vi } from 'vitest';
import { jpegName, SHRINK_STEPS, shrinkToFit, type Compress } from '../src/image/shrink.ts';
import { photo } from './helpers.ts';

const LIMIT = 4 << 20;
const blob = (size: number) => new Blob([new Uint8Array(size)], { type: 'image/jpeg' });

describe('shrinkToFit', () => {
  test('stops at the first step that fits and returns a JPEG named after the photo', async () => {
    const compress = vi
      .fn<Compress>()
      .mockResolvedValueOnce(blob(LIMIT + 1))
      .mockResolvedValueOnce(blob(3 << 20));
    const original = photo('IMG_0001.HEIC', 'image/heic', 6 << 20);
    const result = await shrinkToFit(original, LIMIT, compress);
    expect(compress.mock.calls.map((c) => c[1])).toEqual(SHRINK_STEPS.slice(0, 2));
    expect(compress).toHaveBeenCalledWith(original, SHRINK_STEPS[0]);
    expect(result).toBeInstanceOf(File);
    expect([result?.name, result?.type, result?.size]).toEqual(['IMG_0001.jpg', 'image/jpeg', 3 << 20]);
  });

  test('keeps the resolution as long as it can: long edge 4096 first, 2048 last', () => {
    expect(SHRINK_STEPS[0]).toEqual({ maxSize: 4096, quality: 0.9 });
    expect(SHRINK_STEPS.at(-1)).toEqual({ maxSize: 2048, quality: 0.8 });
    expect(SHRINK_STEPS.every((s) => s.maxSize <= 4096)).toBe(true); // iOS canvas limit
  });

  test('gives up when no step fits', async () => {
    const compress = vi.fn<Compress>().mockResolvedValue(blob(LIMIT + 1));
    expect(await shrinkToFit(photo('a.jpg', 'image/jpeg', 8 << 20), LIMIT, compress)).toBeUndefined();
    expect(compress).toHaveBeenCalledTimes(SHRINK_STEPS.length);
  });

  test('gives up when the browser cannot decode the photo (e.g. HEIC before iOS 17)', async () => {
    const compress = vi.fn<Compress>().mockRejectedValue(new Error('Failed to load the image.'));
    expect(await shrinkToFit(photo('a.heic', 'image/heic', 6 << 20), LIMIT, compress)).toBeUndefined();
    expect(compress).toHaveBeenCalledTimes(1);
  });
});

test.each([
  ['IMG_0001.HEIC', 'IMG_0001.jpg'],
  ['photo.jpeg', 'photo.jpg'],
  ['scan.v2.png', 'scan.v2.jpg'],
  ['noext', 'noext.jpg'],
  ['.heic', 'image.jpg'],
])('jpegName(%s) = %s', (name, expected) => {
  expect(jpegName(name)).toBe(expected);
});
