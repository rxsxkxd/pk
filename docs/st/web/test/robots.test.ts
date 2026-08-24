// The site is kept out of search results; anyone with the link may still view it (infra/NOINDEX.md). The meta tag is
// the fallback for the X-Robots-Tag header that CloudFront and the API add.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, test } from 'vitest';

test('index.html asks search engines not to index it', () => {
  // Vitest runs in web/ (import.meta.url is not a file: URL under happy-dom).
  const html = readFileSync(resolve(process.cwd(), 'index.html'), 'utf8');
  expect(html).toContain('<meta name="robots" content="noindex, nofollow" />');
});
