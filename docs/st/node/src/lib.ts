// Ticket QR API — Node.js implementation. Same API, templates and test vectors as the Go version
// (spec: ../../DESIGN.md, Node-specific decisions: ../../NODE.md). Importing this module has no side
// effects. HTTP routing and the Lambda event conversion are done by Hono (@hono/aws-lambda).
//
// Reading order (each section names the Go file it mirrors):
//   1. Apps and route table           — what the Lambda functions expose
//   2. Endpoints                      — A / B-1 / B-3 / B-2 and example.com
//   3. Issue flow                     — validate → analyze → generate code
//   4. Domain rules                   — ticket code, signer, image check, analyzer, QR
//   5. I/O                            — config and salts, templates, multipart, responses
//   6. Errors and logging

import { createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse as parseContentType } from 'content-type';
import { Hono, type Context } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import { correction, generate } from 'lean-qr';
import { toPngBuffer } from 'lean-qr/extras/node_export';

// Lambda passes the API Gateway request context as a Hono binding; the local server passes none.
type Env = { Bindings: { requestContext?: { requestId?: string } } };
type Ctx = Context<Env>;

export type Deps = {
  config: Config;
  analyzer: Analyzer;
  signer: Signer;
  views: Views;
  newTicket: () => Ticket;
  log: Log;
};

// =================================================================================================
// 1. Apps and route table  (↔ go/internal/app/app.go, go/internal/handler/route.go)
// =================================================================================================

type Endpoint = (c: Ctx, deps: Deps) => Promise<Response>;

// Same routes as API Gateway HTTP API ({ticketCode} is written :ticketCode in Hono).
// prettier-ignore
const ROUTES: ReadonlyArray<readonly ['GET' | 'POST', string, string, 'json' | 'html', Endpoint]> = [
  // method  path                            log name        errors  handler
  ['POST',   '/v1/tickets/qr-inline',        'issue-inline', 'json', issueInline],
  ['POST',   '/v1/tickets',                  'issue',        'html', issue],
  ['GET',    '/v1/tickets/:ticketCode/view', 'get-view',     'html', getView],
  ['GET',    '/v1/tickets/:ticketCode/qr',   'get-qr',       'json', getQr],
];

// ルート表を API Gateway のルートキー表記（"GET /v1/tickets/{ticketCode}/qr"）で返す（Go 版との一致確認用）。
export const ROUTE_KEYS = /* @__PURE__ */ ROUTES.map(([m, path]) => `${m} ${path.replace(/:(\w+)/g, '{$1}')}`);

// 設定・salt・テンプレートを読み込み依存部品を組み立てる（Lambda 実行環境ごとに初期化時に1回だけ呼ぶ）。
export async function loadDeps(env: NodeJS.ProcessEnv = process.env): Promise<Deps> {
  const config = loadConfig(env);
  const analyzer = newAnalyzer(config.analyzerMode);
  const salts = await loadSalts(env);
  const signer = newSigner(salts.current, salts.previous);
  const views = loadViews(env.TEMPLATES_DIR ?? fileURLToPath(new URL('./templates/', import.meta.url)));
  return { config, analyzer, signer, views, newTicket: () => generateTicket(config.suffixLength), log: consoleLog };
}

// ルート表からチケット系エンドポイントの Hono アプリを組み立てる（未定義のルートは 404 JSON）。
export function createApp(deps: Deps): Hono<Env> {
  const app = new Hono<Env>();
  for (const [method, path, name, errors, endpoint] of ROUTES) {
    app.on(method, path, (c) => run(c, deps, name, errors, () => endpoint(c, deps)));
  }
  app.notFound((c) =>
    run(c, deps, 'unknown', 'json', async () => {
      throw notFound();
    }),
  );
  return app;
}

// 処理を実行してリクエストログを出し、例外はエンドポイントの形式のエラーレスポンスに変換する（例外を外に投げない）。
async function run(c: Ctx, deps: Deps, endpoint: string, errors: 'json' | 'html', fn: () => Promise<Response>) {
  const start = performance.now();
  const ctx = { requestId: c.env?.requestContext?.requestId ?? randomUUID(), endpoint };
  let res: Response;
  try {
    res = await fn();
  } catch (err) {
    const e = err instanceof AppError ? err : internal();
    if (e.status >= 500) deps.log('ERROR', 'request failed', { ...ctx, error: String(err) });
    res = errors === 'html' ? htmlError(c, deps, e) : jsonError(c, e);
  }
  deps.log('INFO', 'request completed', {
    ...ctx,
    status: res.status,
    durationMs: Math.round(performance.now() - start),
  });
  return res;
}

// =================================================================================================
// 2. Endpoints  (↔ go/internal/handler/handler.go, go/internal/exampleqr)
// =================================================================================================

// A: 画像を受け取って発行し、QR を base64 で埋め込んだ JSON を返す（DESIGN.md 5.1）。
async function issueInline(c: Ctx, deps: Deps): Promise<Response> {
  const t = await issueTicket(deps, await readFormImage(c));
  const png = qrPng(t.code);
  return jsonResponse(c, 201, {
    ticketCode: t.code,
    issuedAt: t.issuedAt,
    qr: { mimeType: 'image/png', data: png.toString('base64') },
  });
}

// B-1: フォーム送信された画像で発行し、署名付きビュー URL へ 303 で転送する（DESIGN.md 5.2）。
async function issue(c: Ctx, deps: Deps): Promise<Response> {
  const t = await issueTicket(deps, await readFormImage(c));
  return c.body(null, 303, { Location: ticketUrl(deps, t.code, 'view'), ...COMMON_HEADERS });
}

// B-3: sig を検証し、署名付き QR URL を埋め込んだ HTML を返す（DESIGN.md 5.3）。
async function getView(c: Ctx, deps: Deps): Promise<Response> {
  const code = verified(c, deps);
  return htmlResponse(c, deps, 200, deps.views.ticket(code, ticketUrl(deps, code, 'qr')));
}

// B-2: sig を検証し、チケットコードの QR PNG をその場で生成して返す（DESIGN.md 5.4）。
async function getQr(c: Ctx, deps: Deps): Promise<Response> {
  return pngResponse(c, qrPng(verified(c, deps)));
}

// パスのチケットコードを sig と照合して返す。不一致なら 403（コード自体の形式は検査しない）。
function verified(c: Ctx, deps: Deps): string {
  const code = c.req.param('ticketCode') ?? '';
  if (!code || !deps.signer.verify(code, c.req.query('sig') ?? '')) throw forbidden();
  return code;
}

// チケットコードのビュー / QR を指す署名付きの絶対 URL を組み立てる。
function ticketUrl(deps: Deps, code: string, resource: 'view' | 'qr'): string {
  const path = `/v1/tickets/${encodeURIComponent(code)}/${resource}`;
  return `${deps.config.publicBaseUrl}${path}?sig=${encodeURIComponent(deps.signer.sign(code))}`;
}

// GET /v1/example/qr — fixed QR for https://example.com, deployed as its own package (exampleqr.zip).
export const EXAMPLE_CONTENT = 'https://example.com'; // with scheme so readers open it as a link

// example.com の固定 QR を PNG で返す Hono アプリを作る（別パッケージ exampleqr.zip 用。設定不要）。
export function createExampleApp(): Hono<Env> {
  return new Hono<Env>().get('/v1/example/qr', (c) => {
    try {
      return pngResponse(c, qrPng(EXAMPLE_CONTENT));
    } catch (err) {
      consoleLog('ERROR', 'render qr failed', { requestId: c.env?.requestContext?.requestId, error: String(err) });
      return jsonError(c, internal());
    }
  });
}

// =================================================================================================
// 3. Issue flow  (↔ go/internal/usecase/issue.go)
// =================================================================================================

// 画像を検証して解析サーバーに問い合わせ、valid のときだけチケットコードを採番する。
async function issueTicket(deps: Deps, image: Uint8Array): Promise<Ticket> {
  const mimeType = validateImage(image);

  let res: AnalyzerResult;
  try {
    res = await deps.analyzer({ data: image, mimeType });
  } catch (err) {
    if (err instanceof AnalyzerError && err.kind === 'timeout') throw analysisTimeout();
    deps.log('ERROR', 'image analysis failed', { error: String(err) });
    throw analysisUpstream();
  }
  if (!res.valid) {
    deps.log('INFO', 'image rejected', { reason: res.reason });
    throw imageInvalid('image was rejected');
  }

  const t = deps.newTicket();
  deps.log('INFO', 'ticket issued', { ticketCode: t.code, issuedAt: t.issuedAt, analysisReason: res.reason });
  return t;
}

// =================================================================================================
// 4. Domain rules — pure functions, checked against ../testdata shared with Go
// =================================================================================================

// ---- ticket code: {YYYYMMDDHHmmss}-{suffix}  (↔ go/internal/ticketcode, DESIGN.md 4)

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford Base32 (no I, L, O, U)
const JST_OFFSET_MS = 9 * 60 * 60 * 1000; // fixed offset; no tz database needed

export type Ticket = { code: string; issuedAt: string }; // issuedAt: RFC 3339 in JST

// JST の発行日時と乱数 suffix からチケットコードを生成する（時刻と乱数源はテスト用に差し替え可能）。
export function generateTicket(
  suffixLength: number,
  now: Date = new Date(),
  random: (size: number) => Uint8Array = randomBytes,
): Ticket {
  const bytes = random(suffixLength);
  if (bytes.length < suffixLength) throw new Error('read random: short read');
  // 256 is a multiple of 32, so the low 5 bits of each byte are uniform.
  const suffix = Array.from(bytes.subarray(0, suffixLength), (b) => ALPHABET[b & 31]).join('');

  const jst = new Date(now.getTime() + JST_OFFSET_MS);
  const p = (n: number) => String(n).padStart(2, '0');
  const [y, mo, d, h, mi, s] = [
    String(jst.getUTCFullYear()),
    p(jst.getUTCMonth() + 1),
    p(jst.getUTCDate()),
    p(jst.getUTCHours()),
    p(jst.getUTCMinutes()),
    p(jst.getUTCSeconds()),
  ];
  return { code: `${y}${mo}${d}${h}${mi}${s}-${suffix}`, issuedAt: `${y}-${mo}-${d}T${h}:${mi}:${s}+09:00` };
}

// ---- signer: first 22 chars of base64url(HMAC-SHA256(salt, code))  (↔ go/internal/signer, DESIGN.md 5.5)

const SIG_LENGTH = 22;

export type Signer = { sign(ticketCode: string): string; verify(ticketCode: string, sig: string): boolean };

// 現行（と移行期間中は旧）の salt で、sig の生成と照合を行う Signer を作る。
export function newSigner(current: string, previous?: string): Signer {
  if (!current) throw new Error('signing salt is empty');
  const keys = previous ? [current, previous] : [current];
  const sign = (key: string, code: string) =>
    createHmac('sha256', key).update(code).digest('base64url').slice(0, SIG_LENGTH);

  return {
    sign: (code) => sign(current, code),
    verify: (code, sig) => {
      const given = Buffer.from(sig);
      if (sig.length !== SIG_LENGTH || given.length !== SIG_LENGTH) return false;
      return keys.some((k) => timingSafeEqual(Buffer.from(sign(k, code)), given));
    },
  };
}

// ---- image check  (↔ go/internal/imageinput)

export const MAX_IMAGE_BYTES = 4 << 20;

const SIGNATURES: ReadonlyArray<readonly [string, readonly number[]]> = [
  ['image/jpeg', [0xff, 0xd8, 0xff]],
  ['image/png', [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]],
];

// サイズ上限とマジックバイトで画像を検証し、判定した MIME タイプを返す。
export function validateImage(data: Uint8Array): string {
  if (data.length === 0) throw badRequest('image is empty');
  if (data.length > MAX_IMAGE_BYTES) throw payloadTooLarge(`image must be ${MAX_IMAGE_BYTES} bytes or less`);
  for (const [mime, magic] of SIGNATURES) {
    if (magic.every((b, i) => data[i] === b)) return mime;
  }
  throw unsupportedMediaType('image must be JPEG or PNG');
}

// ---- image analysis  (↔ go/internal/analyzer, DESIGN.md 7)
// Request format is fixed: POST, Content-Type application/octet-stream, the uploaded bytes as-is.
// Endpoint, auth and response format are not decided yet, so only a mock exists.

export type AnalyzerResult = { valid: boolean; reason: string };
export type Analyzer = (image: { data: Uint8Array; mimeType: string }) => Promise<AnalyzerResult>;

// 解析サーバーの通信失敗（502）/ タイムアウト（504）を表すエラー（本物のクライアントが投げる）。
export class AnalyzerError extends Error {
  kind: 'upstream' | 'timeout';
  constructor(kind: 'upstream' | 'timeout', message: string) {
    super(message);
    this.kind = kind;
  }
}

// 常に valid を返す画像解析のモック。
export const alwaysValid: Analyzer = async () => ({ valid: true, reason: 'mock' });

// ANALYZER_MODE に応じた画像解析クライアントを返す（現状は mock のみ）。
export function newAnalyzer(mode: string): Analyzer {
  if (mode === 'mock') return alwaysValid;
  throw new Error(`unsupported ANALYZER_MODE "${mode}"`);
}

// ---- QR  (↔ go/internal/qr)

const QR_MAX_PX = 256;
const QUIET_ZONE = 4;

// テキストを誤り訂正 M・余白4モジュールの QR PNG にする（256px 以内に収まる最大の整数倍。NODE.md 3）。
export function qrPng(text: string): Buffer {
  const code = generate(text, { minCorrectionLevel: correction.M, maxCorrectionLevel: correction.M });
  const scale = Math.max(1, Math.floor(QR_MAX_PX / (code.size + 2 * QUIET_ZONE)));
  const png = toPngBuffer(code, { on: [0, 0, 0], off: [255, 255, 255], pad: QUIET_ZONE, scale });
  return Buffer.from(png.buffer, png.byteOffset, png.byteLength);
}

// =================================================================================================
// 5. I/O
// =================================================================================================

// ---- config and salts  (↔ go/internal/config, go/internal/secret)

export type Config = {
  publicBaseUrl: string; // absolute, no trailing slash
  publicOrigin: string; // scheme://host[:port], for CSP
  suffixLength: number;
  analyzerMode: string;
};

const DEFAULT_SUFFIX_LENGTH = 8;

// 環境変数を読み込んで検証し、Config を返す。
export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const base = (env.PUBLIC_BASE_URL ?? '').replace(/\/+$/, '');
  let url: URL | undefined;
  try {
    url = new URL(base);
  } catch {}
  if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) {
    throw new Error(`PUBLIC_BASE_URL must be an absolute http(s) URL, got "${base}"`);
  }

  let suffixLength = DEFAULT_SUFFIX_LENGTH;
  if (env.TICKET_SUFFIX_LENGTH) {
    suffixLength = Number(env.TICKET_SUFFIX_LENGTH);
    if (!Number.isInteger(suffixLength) || suffixLength < 1 || suffixLength > 32) {
      throw new Error(`TICKET_SUFFIX_LENGTH must be 1-32, got "${env.TICKET_SUFFIX_LENGTH}"`);
    }
  }

  return { publicBaseUrl: base, publicOrigin: url.origin, suffixLength, analyzerMode: env.ANALYZER_MODE ?? '' };
}

type Salts = { current: string; previous?: string };

// Secrets Manager から salt を取得する（APP_ENV=local のときだけ環境変数 SIGNING_SALT の平文を使う）。
async function loadSalts(env: NodeJS.ProcessEnv): Promise<Salts> {
  if (env.SIGNING_SALT_SECRET_ID) {
    // Provided by the Lambda runtime; not bundled.
    const { SecretsManagerClient, GetSecretValueCommand } = await import('@aws-sdk/client-secrets-manager');
    const out = await new SecretsManagerClient({}).send(
      new GetSecretValueCommand({ SecretId: env.SIGNING_SALT_SECRET_ID }),
    );
    return JSON.parse(out.SecretString ?? '{}') as Salts;
  }
  if (env.APP_ENV === 'local' && env.SIGNING_SALT) {
    return { current: env.SIGNING_SALT };
  }
  throw new Error('SIGNING_SALT_SECRET_ID is not set');
}

// ---- views: shared ../templates  (↔ go/internal/view)

// Same replacements as Go html/template's HTML escaper, so both versions render identical HTML.
// prettier-ignore
const HTML_ESCAPES: Record<string, string> = {
  '\0': '�', '"': '&#34;', '&': '&amp;', "'": '&#39;', '+': '&#43;', '<': '&lt;', '>': '&gt;',
};
// Go の html/template と同じ置換規則で HTML エスケープする。
const escapeHtml = (s: string) => s.replace(/[\0"&'+<>]/g, (c) => HTML_ESCAPES[c]);

export type Views = {
  ticket(ticketCode: string, qrUrl: string): string;
  error(code: string, message: string): string;
};

// 共通テンプレートを読み込み、{{.Field}} 以外の構文があれば読み込み時にエラーにする。
export function loadViews(dir: string): Views {
  const load = (name: string, fields: string[]) => {
    const tpl = readFileSync(`${dir.replace(/\/+$/, '')}/${name}`, 'utf8');
    for (const m of tpl.matchAll(/\{\{(.*?)\}\}/g)) {
      const field = /^\.(\w+)$/.exec(m[1])?.[1];
      if (!field || !fields.includes(field)) throw new Error(`${name}: unsupported template action ${m[0]}`);
    }
    return (data: Record<string, string>) => tpl.replace(/\{\{\.(\w+)\}\}/g, (_, k: string) => escapeHtml(data[k]));
  };
  const ticket = load('ticket.html', ['TicketCode', 'QRURL']);
  const error = load('error.html', ['Code', 'Message']);
  return {
    ticket: (ticketCode, qrUrl) => ticket({ TicketCode: ticketCode, QRURL: qrUrl }),
    error: (code, message) => error({ Code: code, Message: message }),
  };
}

// ---- request parsing  (↔ readFormImage in go/internal/handler/handler.go)

// multipart/form-data の image フィールドのバイト列をそのまま取り出す（パートの Content-Type は見ない）。
async function readFormImage(c: Ctx): Promise<Uint8Array> {
  // Checked before formData(): it would also accept urlencoded bodies, and a missing boundary must be 415.
  let type = '';
  let boundary: string | undefined;
  try {
    ({
      type,
      parameters: { boundary },
    } = parseContentType(c.req.header('content-type') ?? ''));
  } catch {}
  if (type !== 'multipart/form-data' || !boundary)
    throw unsupportedMediaType('Content-Type must be multipart/form-data');

  let form: FormData;
  try {
    form = await c.req.formData();
  } catch {
    throw badRequest('invalid multipart body');
  }
  const image = form.get('image');
  if (image === null) throw badRequest('image is required');
  return typeof image === 'string' ? Buffer.from(image) : new Uint8Array(await image.arrayBuffer());
}

// ---- responses  (↔ jsonResponse / htmlResponse / withCommon in go/internal/handler/handler.go)
// Headers are set explicitly (not c.json / c.html) so they match the Go version byte for byte.

const COMMON_HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

// 共通ヘッダー付きの JSON レスポンスを作る。
function jsonResponse(c: Ctx, status: number, body: unknown): Response {
  return c.body(JSON.stringify(body), status as ContentfulStatusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    ...COMMON_HEADERS,
  });
}

// CSP などのセキュリティヘッダー付きの HTML レスポンスを作る。
function htmlResponse(c: Ctx, deps: Deps, status: number, body: string): Response {
  return c.body(body, status as ContentfulStatusCode, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Security-Policy': `default-src 'none'; img-src ${deps.config.publicOrigin}; style-src 'unsafe-inline'`,
    'Referrer-Policy': 'no-referrer',
    ...COMMON_HEADERS,
  });
}

// PNG の 200 レスポンスを作る（Lambda では image/png をアダプターが base64 にする）。
function pngResponse(c: Ctx, png: Buffer): Response {
  return c.body(new Uint8Array(png), 200, { 'Content-Type': 'image/png', ...COMMON_HEADERS });
}

// AppError を JSON のエラーレスポンスにする（A / B-2 用）。
function jsonError(c: Ctx, e: AppError): Response {
  return jsonResponse(c, e.status, { error: { code: e.code, message: e.message } });
}

// AppError を HTML のエラービューにする（B-1 / B-3 用）。
function htmlError(c: Ctx, deps: Deps, e: AppError): Response {
  return htmlResponse(c, deps, e.status, deps.views.error(e.code, e.message));
}

// =================================================================================================
// 6. Errors and logging  (↔ go/internal/apperr, slog JSON in go/internal/app)
// =================================================================================================

// HTTP ステータス・エラーコード・メッセージを持つ、API のエラーレスポンスに対応する例外。
export class AppError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

// 各エラーの AppError を作る（メッセージは Go 版と同じ）。
const badRequest = (msg: string) => new AppError(400, 'BAD_REQUEST', msg);
const forbidden = () => new AppError(403, 'FORBIDDEN', 'invalid signature');
const notFound = () => new AppError(404, 'NOT_FOUND', 'route not found');
const payloadTooLarge = (msg: string) => new AppError(413, 'PAYLOAD_TOO_LARGE', msg);
const unsupportedMediaType = (msg: string) => new AppError(415, 'UNSUPPORTED_MEDIA_TYPE', msg);
const imageInvalid = (msg: string) => new AppError(422, 'IMAGE_INVALID', msg);
const analysisUpstream = () => new AppError(502, 'ANALYSIS_UPSTREAM_ERROR', 'image analysis failed');
const analysisTimeout = () => new AppError(504, 'ANALYSIS_TIMEOUT', 'image analysis timed out');
const internal = () => new AppError(500, 'INTERNAL_ERROR', 'internal error');

export type Log = (level: 'INFO' | 'ERROR', msg: string, fields?: Record<string, unknown>) => void;

// Go の slog（JSON）と同じキーで1行の JSON ログを出す。
export const consoleLog: Log = (level, msg, fields) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), level, msg, ...fields }));
