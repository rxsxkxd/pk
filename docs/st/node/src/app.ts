// HTTP layer of the ticket QR API (Hono): route table, endpoints, error handling and middleware, plus
// wiring of the business logic (domain.ts) with its implementations (infra.ts). Same API as the Go
// version (spec: ../../DESIGN.md, Node-specific decisions: ../../NODE.md).

import { randomUUID } from 'node:crypto';
import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { html, raw } from 'hono/html';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import { imageSize } from 'image-size';
import { correction, generate } from 'lean-qr';
import { toPngBuffer } from 'lean-qr/extras/node_export';
import {
  AppError,
  badRequest,
  forbidden,
  generateTicket,
  internal,
  issueTicket,
  newSigner,
  notFound,
  payloadTooLarge,
  unsupportedMediaType,
  type Analyzer,
  type Log,
  type Signer,
  type Ticket,
  type Upload,
} from './domain.ts';
import { consoleLog, loadConfig, loadSalts, newAnalyzer, type Config } from './infra.ts';

type Route = { name: string; errors: 'json' | 'html' };

// Bindings: Lambda passes the API Gateway request context (the local server passes none).
// Variables: the matched route, set by routes() for logging and the error format.
type Env = { Bindings: { requestContext?: { requestId?: string } }; Variables: { route?: Route } };
type Ctx = Context<Env>;

export type Deps = {
  config: Config;
  analyzer: Analyzer;
  signer: Signer;
  newTicket: () => Ticket;
  log: Log;
};

// =================================================================================================
// Route table and wiring  (↔ go/internal/app/app.go, go/internal/handler/route.go)
// =================================================================================================

type Endpoint = (c: Ctx, deps: Deps) => Promise<Response>;

// 設定と salt を読み込み依存部品を組み立てる（Lambda 実行環境ごとに初期化時に1回だけ呼ぶ）。
export async function loadDeps(env: NodeJS.ProcessEnv = process.env): Promise<Deps> {
  const config = loadConfig(env);
  const analyzer = await newAnalyzer(env);
  const salts = await loadSalts(env);
  const signer = newSigner(salts.current, salts.previous);
  return { config, analyzer, signer, newTicket: () => generateTicket(config.suffixLength), log: consoleLog };
}

// チケット系エンドポイントの Hono アプリを組み立てる（ログ・共通ヘッダー・エラー変換を含む）。
export function createApp(deps: Deps): Hono<Env> {
  const csp = `default-src 'none'; img-src ${deps.config.publicOrigin}; style-src 'unsafe-inline'`;
  const app = new Hono<Env>().use(requestLog(deps.log), commonHeaders(csp));

  // Same routes as API Gateway HTTP API ({ticketCode} is written :ticketCode in Hono).
  routes(app, deps)
    .post('/v1/tickets/qr-inline', { name: 'issue-inline', errors: 'json' }, issueInline) // A
    .post('/v1/tickets', { name: 'issue', errors: 'html' }, issue) // B-1
    .get('/v1/tickets/:ticketCode/view', { name: 'get-view', errors: 'html' }, getView) // B-3
    .get('/v1/tickets/:ticketCode/qr', { name: 'get-qr', errors: 'json' }, getQr); // B-2

  app.notFound((c) => c.json(errorBody(notFound()), 404));
  app.onError((err, c) => {
    const e = err instanceof AppError ? err : internal();
    if (e.status >= 500) deps.log('ERROR', 'request failed', { ...logContext(c), error: String(err) });
    const status = e.status as ContentfulStatusCode;
    return c.get('route')?.errors === 'html'
      ? c.html(errorView(e.code, e.message), status)
      : c.json(errorBody(e), status);
  });
  return app;
}

// Hono アプリを包み、ルートごとにログ名・エラー形式・処理を宣言して登録できるようにする。
function routes(app: Hono<Env>, deps: Deps) {
  const add = (method: 'GET' | 'POST') => (path: string, route: Route, endpoint: Endpoint) => {
    app.on(method, path, setRoute(route), (c) => endpoint(c, deps));
    return api;
  };
  const api = { get: add('GET'), post: add('POST') };
  return api;
}

// =================================================================================================
// Middleware
// =================================================================================================

// マッチしたルートの名前とエラー形式をコンテキストに記録する。
const setRoute =
  (route: Route): MiddlewareHandler<Env> =>
  async (c, next) => {
    c.set('route', route);
    await next();
  };

// リクエストごとに完了ログ（ステータス・所要時間）を出す。
const requestLog =
  (log: Log): MiddlewareHandler<Env> =>
  async (c, next) => {
    const start = performance.now();
    await next();
    log('INFO', 'request completed', {
      ...logContext(c),
      status: c.res.status,
      durationMs: Math.round(performance.now() - start),
    });
  };

// すべてのレスポンスに共通ヘッダー（キャッシュ禁止・nosniff・Referrer-Policy、指定があれば CSP）を付ける。
const commonHeaders =
  (csp?: string): MiddlewareHandler<Env> =>
  async (c, next) => {
    await next();
    c.header('Cache-Control', 'no-store');
    c.header('X-Content-Type-Options', 'nosniff');
    c.header('Referrer-Policy', 'no-referrer');
    if (csp) c.header('Content-Security-Policy', csp);
  };

// ログに付けるリクエスト ID とルート名を返す（ローカル実行では ID を生成する）。
function logContext(c: Ctx) {
  return { requestId: c.env?.requestContext?.requestId ?? randomUUID(), endpoint: c.get('route')?.name ?? 'unknown' };
}

// AppError を JSON のエラーレスポンスの本文にする。
function errorBody(e: AppError) {
  return { error: { code: e.code, message: e.message } };
}

// =================================================================================================
// Endpoints  (↔ go/internal/handler/handler.go, go/internal/exampleqr)
// =================================================================================================

// A: 画像を受け取って発行し、QR を base64 で埋め込んだ JSON を返す（DESIGN.md 5.1）。
async function issueInline(c: Ctx, deps: Deps): Promise<Response> {
  const t = await issueTicket(deps, await readUpload(c));
  const png = qrPng(t.code);
  return c.json(
    { ticketCode: t.code, issuedAt: t.issuedAt, qr: { mimeType: 'image/png', data: png.toString('base64') } },
    201,
  );
}

// B-1: フォーム送信された画像で発行し、署名付きビュー URL へ 303 で転送する（DESIGN.md 5.2）。
async function issue(c: Ctx, deps: Deps): Promise<Response> {
  const t = await issueTicket(deps, await readUpload(c));
  return c.redirect(ticketUrl(deps, t.code, 'view'), 303);
}

// B-3: sig を検証し、署名付き QR URL を埋め込んだ HTML を返す（DESIGN.md 5.3）。
async function getView(c: Ctx, deps: Deps): Promise<Response> {
  const code = verified(c, deps);
  return c.html(ticketView(code, ticketUrl(deps, code, 'qr')));
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

// Upload limit set by the runtime: a Lambda request is at most 6MB and binary bodies are base64 (×4/3).
export const MAX_IMAGE_BYTES = 4 << 20;

// image-size's type → MIME type (heic / mif1 are HEIF brands). Which of these are accepted is decided in
// domain.ts.
const DETECTED_TYPES: Record<string, string> = {
  jpg: 'image/jpeg',
  png: 'image/png',
  heic: 'image/heic',
  heif: 'image/heif',
  mif1: 'image/heif',
  avif: 'image/avif',
  webp: 'image/webp',
};

// multipart/form-data の image ファイルを取り出し、サイズ上限を確かめて形式を判定する（バイト列は加工しない）。
async function readUpload(c: Ctx): Promise<Upload> {
  if (!/^multipart\/form-data\b/i.test(c.req.header('content-type') ?? '')) {
    throw unsupportedMediaType('Content-Type must be multipart/form-data');
  }
  const file = await c.req.formData().then(
    (form) => form.get('image'),
    () => null,
  );
  if (!(file instanceof File)) throw badRequest('image file is required');
  const data = new Uint8Array(await file.arrayBuffer());
  if (data.length > MAX_IMAGE_BYTES) throw payloadTooLarge(`image must be ${MAX_IMAGE_BYTES} bytes or less`);
  return { data, detectedType: detectImageType(data) };
}

// 画像ヘッダーを image-size で解析して MIME タイプを返す（画像として読めなければ undefined）。
export function detectImageType(data: Uint8Array): string | undefined {
  try {
    return DETECTED_TYPES[imageSize(data).type ?? ''];
  } catch {
    return undefined;
  }
}

// PNG の 200 レスポンスを作る（Lambda では image/png をアダプターが base64 にする）。
function pngResponse(c: Ctx, png: Buffer): Response {
  return c.body(new Uint8Array(png), 200, { 'Content-Type': 'image/png' });
}

// GET /v1/example/qr — fixed QR for https://example.com, deployed as its own package (exampleqr.zip).
export const EXAMPLE_CONTENT = 'https://example.com'; // with scheme so readers open it as a link

// example.com の固定 QR を PNG で返す Hono アプリを作る（別パッケージ exampleqr.zip 用。設定不要）。
export function createExampleApp(): Hono<Env> {
  return new Hono<Env>().use(commonHeaders()).get('/v1/example/qr', (c) => pngResponse(c, qrPng(EXAMPLE_CONTENT)));
}

// =================================================================================================
// Views: HTML and the QR PNG — how responses are rendered  (↔ go/internal/view, go/internal/qr)
// Node's own HTML; the Go version uses ../../templates — kept equivalent, not byte-identical.
// =================================================================================================

type View = ReturnType<typeof html>;

// A plain string embedded with raw(), so bundles that render no HTML (exampleqr) drop it.
const STYLE = `<style>
  body { margin: 0; font-family: system-ui, sans-serif; background: #fff; color: #111; }
  main { max-width: 360px; margin: 0 auto; padding: 32px 16px; text-align: center; }
  img { width: 256px; height: 256px; }
  .code { font-family: ui-monospace, monospace; font-size: 18px; letter-spacing: 0.05em; }
</style>`;

// チケット画面の HTML を返す（埋め込む値は hono/html が自動でエスケープする）。
function ticketView(code: string, qrUrl: string): View {
  return html`<!doctype html>
    <html lang="ja">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>チケット ${code}</title>
        ${raw(STYLE)}
      </head>
      <body>
        <main data-ticket-code="${code}">
          <h1>チケット</h1>
          <img src="${qrUrl}" alt="チケットQRコード" width="256" height="256" />
          <p class="code">${code}</p>
        </main>
      </body>
    </html> `;
}

// エラー画面の HTML を返す。
function errorView(code: string, message: string): View {
  return html`<!doctype html>
    <html lang="ja">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>エラー</title>
        ${raw(STYLE)}
      </head>
      <body>
        <main data-error-code="${code}">
          <h1>チケットを表示できません</h1>
          <p>${message}</p>
        </main>
      </body>
    </html> `;
}

const QR_MAX_PX = 256;
const QUIET_ZONE = 4;

// テキストを誤り訂正 M・余白4モジュールの QR PNG にする（256px 以内に収まる最大の整数倍。NODE.md 3）。
export function qrPng(text: string): Buffer {
  const code = generate(text, { minCorrectionLevel: correction.M, maxCorrectionLevel: correction.M });
  const scale = Math.max(1, Math.floor(QR_MAX_PX / (code.size + 2 * QUIET_ZONE)));
  const png = toPngBuffer(code, { on: [0, 0, 0], off: [255, 255, 255], pad: QUIET_ZONE, scale });
  return Buffer.from(png.buffer, png.byteOffset, png.byteLength);
}
