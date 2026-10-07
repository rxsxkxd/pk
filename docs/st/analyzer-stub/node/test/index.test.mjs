import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { ApiKey } from '../analyzer.mjs';
import { loadApiKey, respond } from '../index.mjs';

const apiKey = new ApiKey('test-key');

const { cases } = JSON.parse(readFileSync(new URL('../../testdata/cases.json', import.meta.url), 'utf8'));

// テスト用の Function URL イベントを作る（octet-stream は Lambda が base64 で渡す）。
function event({ method = 'POST', path = '/v1/analyze', apiKey = 'test-key', contentType = 'application/octet-stream', body }) {
  const headers = { 'content-type': contentType };
  if (apiKey !== null) headers['x-api-key'] = apiKey;
  return { rawPath: path, headers, body: body.toString('base64'), isBase64Encoded: true, requestContext: { requestId: 't', http: { method } } };
}

for (const c of cases) {
  test(c.name, () => {
    const logs = [];
    const body = Buffer.from(c.bodyHex, 'hex');

    const res = respond(event({ ...c, body }), { apiKey, log: (f) => logs.push(f) });

    assert.equal(res.statusCode, c.status, res.body);
    assert.equal(logs.length, 1);
    if (c.status === 200) {
      assert.equal(JSON.parse(res.body).valid, c.valid);
      // The log proves the bytes arrived unchanged: same length and SHA-256 as what was sent.
      assert.equal(logs[0].bytes, body.length);
      assert.equal(logs[0].sha256, createHash('sha256').update(body).digest('hex'));
    }
  });
}

test('header names are case-insensitive', () => {
  const res = respond(
    {
      ...event({ body: Buffer.from('ffd8ff', 'hex') }),
      headers: { 'Content-Type': 'application/octet-stream', 'X-Api-Key': 'test-key' },
    },
    { apiKey, log: () => {} },
  );
  assert.equal(res.statusCode, 200);
});

test('same response body and log keys as the Python stub', () => {
  const logs = [];
  const res = respond(event({ body: Buffer.from('ffd8ff', 'hex') }), { apiKey, log: (f) => logs.push(f) });
  assert.equal(res.body, '{"valid":true,"reason":"stub"}');
  assert.deepEqual(Object.keys(logs[0]), ['level', 'msg', 'requestId', 'status', 'bytes', 'sha256', 'valid']);
});

test('API key comes from Parameter Store, or from STUB_API_KEY only when APP_ENV=local', async () => {
  assert.equal(await loadApiKey({ APP_ENV: 'local', STUB_API_KEY: 'k' }), 'k');
  for (const env of [{}, { STUB_API_KEY: 'k' }, { APP_ENV: 'local', STUB_API_KEY: '' }]) {
    await assert.rejects(loadApiKey(env), /API_KEY_PARAMETER_NAME/);
  }
});
