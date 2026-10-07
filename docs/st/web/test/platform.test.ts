import { describe, expect, test } from 'vitest';
import { isAndroid } from '../src/platform.ts';

const nav = (userAgent: string, platform?: string) =>
  ({ userAgent, ...(platform === undefined ? {} : { userAgentData: { platform } }) }) as unknown as Navigator;

const ANDROID_UA =
  'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';
const IPHONE_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';

describe('isAndroid', () => {
  test('Client Hints platform is Android', () => expect(isAndroid(nav(ANDROID_UA, 'Android'))).toBe(true));
  test('User-Agent only (no Client Hints, e.g. Firefox)', () => expect(isAndroid(nav(ANDROID_UA))).toBe(true));
  test('iPhone', () => expect(isAndroid(nav(IPHONE_UA))).toBe(false));
  test('desktop Chrome', () =>
    expect(isAndroid(nav('Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140.0.0.0', 'Windows'))).toBe(false));
});
