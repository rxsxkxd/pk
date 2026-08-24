// The favicon is a placeholder to be replaced by a PNG of the same name (DEPLOY.md 6.1). index.html links it from
// src/assets so that the build gives it a hashed name (assets/favicon-<hash>.png), cached like the other assets.
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, test } from 'vitest';

// Vitest runs in web/ (import.meta.url is not a file: URL under happy-dom).
const at = (path: string) => resolve(process.cwd(), path);

test('index.html links the favicon in src/assets, and the file is there', () => {
  const html = readFileSync(at('index.html'), 'utf8');
  expect(html).toMatch(/<link rel="icon" type="image\/png" href="\/src\/assets\/favicon\.png" \/>/);
  const png = readFileSync(at('src/assets/favicon.png'));
  expect([...png.subarray(0, 8)]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]); // a PNG
  expect(existsSync(at('public/favicon.png'))).toBe(false); // not in public/ (no hash, cached for a year)
});
