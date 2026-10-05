import { describe, expect, test } from 'vitest';
import { ConfigSchema } from '../src/config.ts';

describe('config.json', () => {
  test('modes default to the main page mode', () => {
    expect(ConfigSchema.parse({ apiBaseUrl: 'https://api.example.com' })).toEqual({
      apiBaseUrl: 'https://api.example.com',
      modes: ['page'],
    });
  });

  test('trailing slashes are removed and "" means the same origin', () => {
    expect(ConfigSchema.parse({ apiBaseUrl: 'https://api.example.com/' }).apiBaseUrl).toBe('https://api.example.com');
    expect(ConfigSchema.parse({ apiBaseUrl: '' }).apiBaseUrl).toBe('');
  });

  test.each([
    ['missing apiBaseUrl', {}],
    ['not a URL', { apiBaseUrl: 'api.example.com' }],
    ['not http(s)', { apiBaseUrl: 'ftp://api.example.com' }],
    ['unknown mode', { apiBaseUrl: '', modes: ['page', 'b'] }],
    ['no modes', { apiBaseUrl: '', modes: [] }],
  ])('%s is rejected', (_name, value) => {
    expect(ConfigSchema.safeParse(value).success).toBe(false);
  });
});
