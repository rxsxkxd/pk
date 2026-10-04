// Image analysis server stub (Node.js) for checking the ticket API on AWS Lambda. Runs behind a Lambda
// Function URL (payload format 2.0). It does no analysis: every accepted image is valid (see
// ../DESIGN.md). No dependencies; the AWS SDK comes with the Lambda runtime.

import { createHash, timingSafeEqual } from 'node:crypto';

// Lambda のハンドラー。初回の呼び出し時に API キーを読み込み、以降は使い回す。
let ready;
export const handler = async (event) => (await (ready ??= loadApiKey(process.env).then(createHandler)))(event);

// Secrets Manager から API キーを読み込む（APP_ENV=local のときだけ STUB_API_KEY の平文を使う）。
export async function loadApiKey(env) {
  if (env.API_KEY_SECRET_ID) {
    const { SecretsManagerClient, GetSecretValueCommand } = await import('@aws-sdk/client-secrets-manager');
    const out = await new SecretsManagerClient({}).send(new GetSecretValueCommand({ SecretId: env.API_KEY_SECRET_ID }));
    if (out.SecretString) return out.SecretString;
  } else if (env.APP_ENV === 'local' && env.STUB_API_KEY) {
    return env.STUB_API_KEY;
  }
  throw new Error('API_KEY_SECRET_ID is not set');
}

// API キーからリクエスト処理関数を作る（ログ出力はテスト用に差し替え可能）。
export function createHandler(apiKey, log = consoleLog) {
  const expectedKey = digest(apiKey);

  return async (event) => {
    const requestId = event.requestContext?.requestId;
    const headers = Object.fromEntries(Object.entries(event.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
    const reply = (status, body, fields = {}) => {
      log({ level: 'INFO', msg: 'analyzed', requestId, status, ...fields });
      return { statusCode: status, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
    };

    if (event.requestContext?.http?.method !== 'POST' || event.rawPath !== '/v1/analyze') {
      return reply(404, { error: 'not found' });
    }
    if (!timingSafeEqual(digest(headers['x-api-key'] ?? ''), expectedKey)) return reply(401, { error: 'invalid api key' });

    const contentType = (headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
    if (contentType !== 'application/octet-stream') {
      return reply(400, { error: 'Content-Type must be application/octet-stream' }, { contentType });
    }
    const image = Buffer.from(event.body ?? '', event.isBase64Encoded ? 'base64' : 'utf8');
    if (image.length === 0) return reply(400, { error: 'empty body' });

    // No analysis. bytes and sha256 let us check that the API forwarded the upload unchanged.
    const sha256 = createHash('sha256').update(image).digest('hex');
    return reply(200, { valid: true, reason: 'stub' }, { bytes: image.length, sha256, valid: true });
  };
}

// API キーを比較用の固定長の値（SHA-256）にする（長さの違いで比較時間が変わらないように）。
function digest(key) {
  return createHash('sha256').update(key).digest();
}

// 1行の JSON ログを出す（画像の中身は出さない）。
function consoleLog(fields) {
  console.log(JSON.stringify({ time: new Date().toISOString(), ...fields }));
}
