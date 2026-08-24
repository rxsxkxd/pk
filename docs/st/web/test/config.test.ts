import * as v from 'valibot';
import { describe, expect, test } from 'vitest';
import { ConfigSchema } from '../src/config.ts';

describe('config.json', () => {
  test('defaults', () => {
    expect(v.parse(ConfigSchema, { apiBaseUrl: 'https://api.example.com' })).toEqual({
      apiBaseUrl: 'https://api.example.com',
      maxImageBytes: 4 << 20,
    });
  });

  test('a leftover "modes" (the grant mode is chosen at build time now) is ignored', () => {
    expect(v.parse(ConfigSchema, { apiBaseUrl: '', modes: ['page', 'inline'] })).toEqual({
      apiBaseUrl: '',
      maxImageBytes: 4 << 20,
    });
  });

  test('maxImageBytes can lower the upload limit, not raise it above the API ceiling', () => {
    expect(v.parse(ConfigSchema, { apiBaseUrl: '', maxImageBytes: 1 << 20 }).maxImageBytes).toBe(1 << 20);
    expect(v.safeParse(ConfigSchema, { apiBaseUrl: '', maxImageBytes: (4 << 20) + 1 }).success).toBe(false);
  });

  test('trailing slashes are removed and "" means the same origin', () => {
    expect(v.parse(ConfigSchema, { apiBaseUrl: 'https://api.example.com/' }).apiBaseUrl).toBe(
      'https://api.example.com',
    );
    expect(v.parse(ConfigSchema, { apiBaseUrl: '' }).apiBaseUrl).toBe('');
  });

  test.each([
    ['missing apiBaseUrl', {}],
    ['not a URL', { apiBaseUrl: 'api.example.com' }],
    ['not http(s)', { apiBaseUrl: 'ftp://api.example.com' }],
    ['maxImageBytes 0', { apiBaseUrl: '', maxImageBytes: 0 }],
    ['maxImageBytes not an integer', { apiBaseUrl: '', maxImageBytes: 1.5 }],
  ])('%s is rejected', (_name, value) => {
    expect(v.safeParse(ConfigSchema, value).success).toBe(false);
  });
});
