// HTTP layer of the ticket QR API (Hono): route table, endpoints, error handling and middleware, plus
// wiring of the business logic (domain.ts) with its implementations (infra.ts). Same API as the Go
// version (spec: ../../DESIGN.md, Node-specific decisions: ../../NODE.md).

import { randomUUID } from 'node:crypto';
import { MIMEType } from 'node:util';
import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { html, raw } from 'hono/html';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import {
  AppError,
  badRequest,
  forbidden,
  generateTicket,
  internal,
  verifyAndGrant,
  newSigner,
  notFound,
  payloadTooLarge,
  unsupportedMediaType,
  type Verifier,
  type Log,
  type Signer,
  type Ticket,
  type CertificateImage,
} from './domain.ts';
import { consoleLog, loadConfig, loadSalts, loadTicketCodeSuffix, newAnalyzer, type Config } from './infra.ts';
import { detectImageType, MAX_IMAGE_BYTES } from './image.ts';
import { commonHeaders, pngResponse, qrPng } from './shared.ts';

// errors: response format of errors. 'accept' = JSON when the client asks for it (Accept), else HTML.
type Route = { name: string; errors: 'json' | 'html' | 'accept' };

// Bindings: Lambda passes the API Gateway request context (the local server passes none).
// Variables: the matched route, set by routes() for logging and the error format.
type Env = { Bindings: { requestContext?: { requestId?: string } }; Variables: { route?: Route } };
type Ctx = Context<Env>;

export type Deps = {
  config: Config;
  verifier: Verifier;
  signer: Signer;
  newTicket: () => Ticket;
  log: Log;
};

// =================================================================================================
// Route table and wiring  (↔ go/cmd/ticketqr/wire.go, go/internal/httpapi/route.go)
// =================================================================================================

type Endpoint = (c: Ctx, deps: Deps) => Promise<Response>;

// 設定と salt を読み込み依存部品を組み立てる（Lambda 実行環境ごとに初期化時に1回だけ呼ぶ）。
export async function loadDeps(env: NodeJS.ProcessEnv = process.env): Promise<Deps> {
  const config = loadConfig(env);
  const verifier = await newAnalyzer(env, consoleLog);
  const salts = await loadSalts(env);
  const suffix = await loadTicketCodeSuffix(env);
  generateTicket(suffix); // checks the suffix at start-up, as the Go version does
  const signer = newSigner(salts.current, salts.previous);
  return { config, verifier, signer, newTicket: () => generateTicket(suffix), log: consoleLog };
}

// チケット系エンドポイントの Hono アプリを組み立てる（ログ・共通ヘッダー・エラー変換を含む）。
export function createApp(deps: Deps): Hono<Env> {
  const csp = `default-src 'none'; img-src ${deps.config.publicOrigin}; style-src 'unsafe-inline'`;
  const app = new Hono<Env>().use(requestLog(deps.log), commonHeaders(csp));

  // Same routes as API Gateway HTTP API ({ticketCode} is written :ticketCode in Hono).
  routes(app, deps)
    .post('/v1/tickets/qr-inline', { name: 'grant-inline', errors: 'json' }, grantInline) // A
    .post('/v1/tickets', { name: 'grant', errors: 'accept' }, grant) // B-1
    .get('/v1/tickets/:ticketCode/view', { name: 'get-view', errors: 'html' }, getView) // B-3
    .get('/v1/tickets/:ticketCode/qr', { name: 'get-qr', errors: 'json' }, getQr); // B-2

  app.notFound((c) => c.json(errorBody(notFound()), 404));
  app.onError((err, c) => {
    const e = err instanceof AppError ? err : internal();
    if (e.status >= 500) deps.log('ERROR', 'request failed', { ...logContext(c), error: String(err) });
    const status = e.status as ContentfulStatusCode;
    const errors = c.get('route')?.errors;
    return errors === 'html' || (errors === 'accept' && !acceptsJson(c))
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
    const context = logContext(c);
    const client = CLIENT_ENDPOINTS.has(context.endpoint) ? clientInfo(c) : undefined;
    log('INFO', 'request completed', {
      ...context,
      status: c.res.status,
      durationMs: Math.round(performance.now() - start),
      ...(client && { client }),
    });
  };

// Endpoints that receive images from browsers. Their completion log also records what the browser says
// about itself, so browser and OS versions can be counted in CloudWatch Logs (DESIGN.md 10).
const CLIENT_ENDPOINTS = new Set(['grant-inline', 'grant']);

// Log keys → request headers logged as-is: the User-Agent and the User-Agent Client Hints (same keys as Go).
const CLIENT_HEADERS = {
  userAgent: 'user-agent',
  secChUa: 'sec-ch-ua',
  secChUaMobile: 'sec-ch-ua-mobile',
  secChUaPlatform: 'sec-ch-ua-platform',
  secChUaPlatformVersion: 'sec-ch-ua-platform-version',
};

// Each value is client-controlled, so it is cut to this many characters.
const MAX_CLIENT_HEADER_LENGTH = 512;

// リクエストのブラウザ情報（User-Agent と Client Hints のうち、届いたもの）を返す。1つもなければ undefined。
function clientInfo(c: Ctx): Record<string, string> | undefined {
  const entries = Object.entries(CLIENT_HEADERS)
    .map(([key, name]) => [key, c.req.header(name)?.slice(0, MAX_CLIENT_HEADER_LENGTH)] as const)
    .filter((e): e is readonly [string, string] => !!e[1]);
  return entries.length ? Object.fromEntries(entries) : undefined;
}

// ログに付けるリクエスト ID とルート名を返す（ローカル実行では ID を生成する）。
function logContext(c: Ctx) {
  return { requestId: c.env?.requestContext?.requestId ?? randomUUID(), endpoint: c.get('route')?.name ?? 'unknown' };
}

// AppError を JSON のエラーレスポンスの本文にする。
function errorBody(e: AppError) {
  return { error: { code: e.code, message: e.message } };
}

// =================================================================================================
// Endpoints  (↔ go/internal/httpapi/handler.go)
// =================================================================================================

// A: 画像を受け取って発行し、QR を base64 で埋め込んだ JSON を返す（DESIGN.md 5.1）。
async function grantInline(c: Ctx, deps: Deps): Promise<Response> {
  const t = await verifyAndGrant(deps, await readUpload(c));
  const png = qrPng(t.code);
  return c.json(
    { ticketCode: t.code, issuedAt: t.issuedAt, qr: { mimeType: 'image/png', data: png.toString('base64') } },
    201,
  );
}

// B-1: 画像で発行する。フォーム送信には署名付きビュー URL への 303、Accept: application/json（SPA）には
// 署名付き QR URL の JSON を返す（DESIGN.md 5.2）。
async function grant(c: Ctx, deps: Deps): Promise<Response> {
  const t = await verifyAndGrant(deps, await readUpload(c));
  c.header('Vary', 'Accept');
  if (!acceptsJson(c)) return c.redirect(ticketUrl(deps, t.code, 'view'), 303);
  const sig = deps.signer.sign(t.code);
  return c.json({ ticketCode: t.code, issuedAt: t.issuedAt, sig, qrUrl: ticketUrl(deps, t.code, 'qr') }, 201);
}

// クライアントが JSON の応答を求めているか（Accept に application/json を含むか）を返す。
function acceptsJson(c: Ctx): boolean {
  return /application\/json/i.test(c.req.header('accept') ?? '');
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

// =================================================================================================
// Request → usecase input  (↔ go/internal/httpapi readUpload / readFormImage)
// =================================================================================================

// リクエストを ユースケースの入力（CertificateImage。証明書の画像）に変換する。バイト列は加工せず、サイズ上限の確認と形式の判定だけ行う。
async function readUpload(c: Ctx): Promise<CertificateImage> {
  const data = await readFormImage(c);
  if (data.length > MAX_IMAGE_BYTES) throw payloadTooLarge(`image must be ${MAX_IMAGE_BYTES} bytes or less`);
  return { data, mimeType: detectImageType(data) } satisfies CertificateImage;
}

// multipart/form-data から image ファイルのバイト列を取り出す（HTTP の都合だけを扱う）。
async function readFormImage(c: Ctx): Promise<Uint8Array> {
  if (!isMultipart(c.req.header('content-type'))) {
    throw unsupportedMediaType('Content-Type must be multipart/form-data');
  }
  const form = await c.req.formData().catch(() => {
    throw badRequest('invalid multipart body');
  });
  const file = form.get('image');
  if (!(file instanceof File)) throw badRequest('image is required');
  return new Uint8Array(await file.arrayBuffer());
}

// Content-Type が boundary 付きの multipart/form-data か判定する（formData() と同じ WHATWG の規則で読む）。
function isMultipart(contentType = ''): boolean {
  try {
    const m = new MIMEType(contentType);
    return m.essence === 'multipart/form-data' && !!m.params.get('boundary');
  } catch {
    return false;
  }
}

// =================================================================================================
// Views: HTML  (↔ go/internal/view; the QR PNG is rendered by shared.ts)
// Node's own HTML; the Go version uses go/internal/view/templates — kept equivalent, not byte-identical.
// =================================================================================================

type View = ReturnType<typeof html>;

// A plain string embedded with raw(), so it stays out of the module's side effects.
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
