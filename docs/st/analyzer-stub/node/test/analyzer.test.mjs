// The business rules alone (API key, image judgment): no Lambda event.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { analyze, ApiKey, NoApiKey } from '../analyzer.mjs';

test('every image is valid and fingerprinted', () => {
  const image = Buffer.from('ffd8ffe000104a464946', 'hex');
  assert.deepEqual(analyze(image), {
    valid: true,
    reason: 'stub',
    size: image.length,
    sha256: createHash('sha256').update(image).digest('hex'),
  });
});

test('only the same API key matches', () => {
  const key = new ApiKey('test-key');
  assert.equal(key.matches('test-key'), true);
  for (const given of ['', 'nope', 'test-key-longer', 'TEST-KEY']) assert.equal(key.matches(given), false, given);
});

test('NoApiKey lets everything through', () => {
  assert.equal(new NoApiKey().matches(''), true);
});
