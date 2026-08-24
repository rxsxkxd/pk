// src/main.ts loads the polyfills (core-js) before the libraries that use those built-ins.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, test } from 'vitest';

test('core-js (Object.hasOwn) is imported before pinia', () => {
  const main = readFileSync(resolve(__dirname, '../src/main.ts'), 'utf8');
  const polyfill = main.indexOf("import 'core-js/actual/object/has-own'");
  expect(polyfill).toBeGreaterThanOrEqual(0);
  expect(polyfill).toBeLessThan(main.indexOf("from 'pinia'"));
});
