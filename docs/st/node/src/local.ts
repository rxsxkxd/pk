// Local development server (not bundled). Serves the ticket endpoints on :8080 and the example.com
// QR on :8081, converting each request into an API Gateway HTTP API (v2) event with its routeKey,
// like go/internal/localhttp.

import { randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { fileURLToPath } from 'node:url';
import { EXAMPLE_ROUTE_KEY, exampleQr, loadDeps, route, ROUTE_KEYS, type Event, type Handler } from './lib.ts';

const port = Number(process.env.PORT ?? 8080);
const examplePort = Number(process.env.EXAMPLE_PORT ?? 8081);

const defaults: Record<string, string> = {
  APP_ENV: 'local',
  PUBLIC_BASE_URL: `http://localhost:${port}`,
  SIGNING_SALT: 'local-dev-salt',
  ANALYZER_MODE: 'mock',
  TEMPLATES_DIR: fileURLToPath(new URL('../../templates/', import.meta.url)),
};
for (const [k, v] of Object.entries(defaults)) process.env[k] ??= v;

type Route = { key: string; method: string; pattern: RegExp; handler: Handler };

function compile(key: string, handler: Handler): Route {
  const [method, path] = key.split(' ');
  const pattern = new RegExp(`^${path.replace(/\{(\w+)\}/g, '(?<$1>[^/]+)')}$`);
  return { key, method, pattern, handler };
}

async function toEvent(req: IncomingMessage, r: Route, url: URL, params: Record<string, string>): Promise<Event> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  const headers: Record<string, string> = {};
  for (const [k, v] of Object.entries(req.headers))
    if (v !== undefined) headers[k] = Array.isArray(v) ? v.join(',') : v;
  const query: Record<string, string> = {};
  for (const k of new Set(url.searchParams.keys())) query[k] = url.searchParams.getAll(k).join(',');

  // Only the fields the handlers read; the rest of the API Gateway envelope is irrelevant locally.
  return {
    version: '2.0',
    routeKey: r.key,
    rawPath: url.pathname,
    rawQueryString: url.search.slice(1),
    headers,
    queryStringParameters: query,
    pathParameters: params,
    body: Buffer.concat(chunks).toString('base64'),
    isBase64Encoded: true,
    requestContext: { requestId: randomUUID(), http: { method: req.method ?? '', path: url.pathname } },
  } as unknown as Event;
}

function serve(listenPort: number, routes: Route[], index?: string) {
  createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? '/', `http://localhost:${listenPort}`);
    if (index && req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }).end(index);
      return;
    }
    for (const r of routes) {
      const m = r.method === req.method ? r.pattern.exec(url.pathname) : null;
      if (!m) continue;
      const out = await r.handler(await toEvent(req, r, url, { ...m.groups }));
      const body = Buffer.from(out.body ?? '', out.isBase64Encoded ? 'base64' : 'utf8');
      res.writeHead(out.statusCode ?? 200, out.headers as Record<string, string>).end(body);
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' }).end('404 page not found\n');
  }).listen(listenPort, () => console.log(`listening on :${listenPort} (open http://localhost:${listenPort}/)`));
}

// Stands in for the client page that calls patterns A and B-1 (same as the Go local server).
const uploadForm = `<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>ローカル動作確認</title></head>
<body>
  <h1>パターンA 動作確認（fetch + FormData → JSON）</h1>
  <form id="inline">
    <input type="file" name="image" accept="image/jpeg,image/png" required>
    <button type="submit">発行</button>
  </form>
  <p id="inline-result"></p>
  <img id="inline-qr" alt="">

  <h1>パターンB-1 動作確認（フォーム送信 → 303）</h1>
  <form method="post" action="/v1/tickets" enctype="multipart/form-data">
    <input type="file" name="image" accept="image/jpeg,image/png" required>
    <button type="submit">発行</button>
  </form>

  <script>
    document.getElementById("inline").addEventListener("submit", async (e) => {
      e.preventDefault();
      const res = await fetch("/v1/tickets/qr-inline", { method: "POST", body: new FormData(e.target) });
      const body = await res.json();
      document.getElementById("inline-result").textContent =
        res.ok ? body.ticketCode : res.status + " " + body.error.code;
      document.getElementById("inline-qr").src = res.ok ? "data:" + body.qr.mimeType + ";base64," + body.qr.data : "";
    });
  </script>
</body>
</html>
`;

const tickets = route(await loadDeps());
serve(
  port,
  ROUTE_KEYS.map((k) => compile(k, tickets)),
  uploadForm,
);
serve(examplePort, [compile(EXAMPLE_ROUTE_KEY, exampleQr)]);
