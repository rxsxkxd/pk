// Image analysis server stub (Node.js) for checking the ticket API on AWS Lambda: the Lambda entry point.
// Runs behind a Lambda Function URL (payload format 2.0). This file parses and checks the request (route,
// Content-Type, body; see ../DESIGN.md 3) and logs it; the API key rule and judging the image are
// analyzer.mjs. Same structure as ../python/index.py; both are checked against ../testdata/cases.json.
// No dependencies; the AWS SDK comes with the Lambda runtime.

import { ApiKey, analyze, NoApiKey } from './analyzer.mjs';

// Lambda のハンドラー。初回の呼び出し時に認証の決まり（API キー）を読み込み、以降は使い回す。
let auth; // Promise<ApiKey | NoApiKey>
export async function handler(event) {
  auth ??= loadAuth(process.env);
  return respond(event, { auth: await auth });
}

// 認証の決まりを選ぶ。STUB_AUTH=none を明示したときだけ API キーを確かめない（VPC 内で SG だけで許可する場合）。
// それ以外は API キーが必須（設定漏れで、公開した Function URL のスタブが誰でも呼べる状態にならないように）。
export async function loadAuth(env, log = consoleLog) {
  switch (env.STUB_AUTH ?? 'api-key') {
    case 'none':
      log({ level: 'WARN', msg: 'api key check is disabled (STUB_AUTH=none)' });
      return new NoApiKey();
    case 'api-key':
      return new ApiKey(await loadApiKey(env));
    default:
      throw new Error(`STUB_AUTH must be api-key or none, got "${env.STUB_AUTH}"`);
  }
}

// Parameter Store の SecureString から API キーを読み込む（APP_ENV=local のときだけ STUB_API_KEY の平文を使う）。
export async function loadApiKey(env) {
  if (env.API_KEY_PARAMETER_NAME) {
    const { SSMClient, GetParameterCommand } = await import('@aws-sdk/client-ssm');
    const out = await new SSMClient({}).send(
      new GetParameterCommand({ Name: env.API_KEY_PARAMETER_NAME, WithDecryption: true }),
    );
    if (out.Parameter?.Value) return out.Parameter.Value;
  } else if (env.APP_ENV === 'local' && env.STUB_API_KEY) {
    return env.STUB_API_KEY;
  }
  throw new Error('API_KEY_PARAMETER_NAME is not set');
}

// スタブが見るリクエストの項目を、Function URL のイベントから取り出す。
export function parseRequest(event) {
  const headers = Object.fromEntries(Object.entries(event.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
  return {
    method: event.requestContext?.http?.method ?? '',
    path: event.rawPath ?? '',
    apiKey: headers['x-api-key'] ?? '',
    contentType: (headers['content-type'] ?? '').split(';')[0].trim().toLowerCase(), // パラメーターを外し、小文字に
    body: Buffer.from(event.body ?? '', event.isBase64Encoded ? 'base64' : 'utf8'), // octet-stream は base64 で届く
    requestId: event.requestContext?.requestId,
  };
}

// 応答（ステータスと本文）と、ログに足す項目。
const outcome = (status, body, logFields = {}) => ({ status, body, logFields });
const NOT_FOUND = outcome(404, { error: 'not found' });
const INVALID_API_KEY = outcome(401, { error: 'invalid api key' });
const EMPTY_BODY = outcome(400, { error: 'empty body' });

// Function URL のイベントを受け取り、リクエストを確かめて応答を返す（ログ出力はテスト用に差し替え可能）。
export function respond(event, { auth, log = consoleLog }) {
  const request = parseRequest(event);
  const { status, body, logFields } = checkRequest(request, auth);
  log({ level: 'INFO', msg: 'analyzed', requestId: request.requestId, status, ...logFields });
  return { statusCode: status, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
}

// 仕様（../DESIGN.md 3.2）の順にリクエストを確かめ、通ったものだけ画像の判定（analyzer.mjs）に渡す。API キーの照合も analyzer.mjs。
export function checkRequest(request, auth) {
  if (request.method !== 'POST' || request.path !== '/v1/analyze') return NOT_FOUND;
  if (!auth.matches(request.apiKey)) return INVALID_API_KEY;
  if (request.contentType !== 'application/octet-stream') {
    return outcome(400, { error: 'Content-Type must be application/octet-stream' }, { contentType: request.contentType });
  }
  if (request.body.length === 0) return EMPTY_BODY;

  const result = analyze(request.body);
  return outcome(
    200,
    { valid: result.valid, reason: result.reason },
    { bytes: result.size, sha256: result.sha256, valid: result.valid },
  );
}

// 1行の JSON ログを出す（画像の中身は出さない）。
function consoleLog(fields) {
  console.log(JSON.stringify({ time: new Date().toISOString(), ...fields }));
}
