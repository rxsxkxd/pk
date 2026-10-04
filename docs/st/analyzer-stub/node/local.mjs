// Local server for the stub (not deployed): converts HTTP requests into Lambda Function URL events.
// Run: npm run dev  →  POST http://localhost:8090/v1/analyze  (x-api-key: local-stub-key)

import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { createHandler, loadApiKey } from './index.mjs';

const port = Number(process.env.PORT ?? 8090);
process.env.APP_ENV ??= 'local';
process.env.STUB_API_KEY ??= 'local-stub-key';

const handle = createHandler(await loadApiKey(process.env));

createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const url = new URL(req.url ?? '/', `http://localhost:${port}`);
  const out = await handle({
    rawPath: url.pathname,
    headers: Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, String(v)])),
    body: Buffer.concat(chunks).toString('base64'),
    isBase64Encoded: true,
    requestContext: { requestId: randomUUID(), http: { method: req.method } },
  });
  res.writeHead(out.statusCode, out.headers).end(out.body);
}).listen(port, () => console.log(`analyzer stub listening on :${port}`));
