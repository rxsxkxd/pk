// HTTP layer of the ticket QR API (Hono): route table, endpoints, request parsing and responses, plus
// wiring of the business logic (domain.ts) with its implementations (infra.ts). Same API as the Go
// version (spec: ../../DESIGN.md, Node-specific decisions: ../../NODE.md).

import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Hono, type Context } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import {
  AppError,
  badRequest,
  forbidden,
  generateTicket,
  internal,
  issueTicket,
  newSigner,
  notFound,
  unsupportedMediaType,
  type Analyzer,
  type Log,
  type Signer,
  type Ticket,
} from './domain.ts';
import { consoleLog, loadConfig, loadSalts, loadViews, newAnalyzer, qrPng, type Config, type Views } from './infra.ts';

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
// Route table and wiring  (↔ go/internal/app/app.go, go/internal/handler/route.go)
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
// Endpoints  (↔ go/internal/handler/handler.go, go/internal/exampleqr)
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
// Request parsing and responses  (↔ helpers in go/internal/handler/handler.go)
// =================================================================================================

// multipart/form-data の image ファイルのバイト列をそのまま取り出す（multipart 以外は 415、壊れた形式は 400）。
async function readFormImage(c: Ctx): Promise<Uint8Array> {
  if (!/^multipart\/form-data\b/i.test(c.req.header('content-type') ?? '')) {
    throw unsupportedMediaType('Content-Type must be multipart/form-data');
  }
  const image = await c.req.formData().then(
    (form) => form.get('image'),
    () => null,
  );
  if (!(image instanceof File)) throw badRequest('image file is required');
  return new Uint8Array(await image.arrayBuffer());
}

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
