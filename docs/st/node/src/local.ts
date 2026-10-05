// Local development server (not bundled). Serves the ticket app on :8080 (plus an upload form) and the
// example.com QR app on :8081 with @hono/node-server — the same Hono apps the Lambda functions run.

import { serve } from '@hono/node-server';
import { createApp, createExampleApp, loadDeps } from './app.ts';

const port = Number(process.env.PORT ?? 8080);
const examplePort = Number(process.env.EXAMPLE_PORT ?? 8081);

const defaults: Record<string, string> = {
  APP_ENV: 'local',
  PUBLIC_BASE_URL: `http://localhost:${port}`,
  SIGNING_SALT: 'local-dev-salt',
  ANALYZER_MODE: 'mock',
};
for (const [k, v] of Object.entries(defaults)) process.env[k] ??= v;

// Stands in for the client page that calls patterns A and B-1 (same as the Go local server).
const uploadForm = `<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>ローカル動作確認</title></head>
<body>
  <h1>パターンA 動作確認（fetch + FormData → JSON）</h1>
  <form id="inline">
    <input type="file" name="image" accept="image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp" required>
    <button type="submit">発行</button>
  </form>
  <p id="inline-result"></p>
  <img id="inline-qr" alt="">

  <h1>パターンB-1 動作確認（フォーム送信 → 303）</h1>
  <form method="post" action="/v1/tickets" enctype="multipart/form-data">
    <input type="file" name="image" accept="image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp" required>
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

// Added to the ticket app itself (not a parent app) so its 404 JSON handler still applies.
const tickets = createApp(await loadDeps()).get('/', (c) => c.html(uploadForm));
serve({ fetch: tickets.fetch, port }, () => console.log(`listening on :${port} (open http://localhost:${port}/)`));
serve({ fetch: createExampleApp().fetch, port: examplePort }, () =>
  console.log(`listening on :${examplePort} (open http://localhost:${examplePort}/v1/example/qr)`),
);
