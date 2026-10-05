import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { createHandler, loadApiKey } from '../index.mjs';

const { cases } = JSON.parse(readFileSync(new URL('../../testdata/cases.json', import.meta.url), 'utf8'));

// テスト用の Function URL イベントを作る（octet-stream は Lambda が base64 で渡す）。
function event({ method = 'POST', path = '/v1/analyze', apiKey = 'test-key', contentType = 'application/octet-stream', body }) {
  const headers = { 'content-type': contentType };
  if (apiKey !== null) headers['x-api-key'] = apiKey;
  return { rawPath: path, headers, body: body.toString('base64'), isBase64Encoded: true, requestContext: { requestId: 't', http: { method } } };
}

for (const c of cases) {
  test(c.name, async () => {
    const logs = [];
    const handle = createHandler('test-key', (f) => logs.push(f));
    const body = Buffer.from(c.bodyHex, 'hex');

    const res = await handle(event({ ...c, body }));

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

test('header names are case-insensitive', async () => {
  const handle = createHandler('test-key', () => {});
  const res = await handle({
    ...event({ body: Buffer.from('ffd8ff', 'hex') }),
    headers: { 'Content-Type': 'application/octet-stream', 'X-Api-Key': 'test-key' },
  });
  assert.equal(res.statusCode, 200);
});

test('API key comes from Parameter Store, or from STUB_API_KEY only when APP_ENV=local', async () => {
  assert.equal(await loadApiKey({ APP_ENV: 'local', STUB_API_KEY: 'k' }), 'k');
  await assert.rejects(loadApiKey({}), /API_KEY_PARAMETER_NAME/);
  await assert.rejects(loadApiKey({ STUB_API_KEY: 'k' }), /API_KEY_PARAMETER_NAME/);
});
