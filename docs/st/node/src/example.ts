// GET /v1/example/qr — a fixed QR for https://example.com, deployed as its own package (exampleqr.zip)
// and stack (infra/cloudformation/example.yaml). Unrelated to the ticket API; needs no configuration.
//  (↔ go/internal/exampleqr)

import { Hono } from 'hono';
import { commonHeaders, pngResponse, qrPng } from './shared.ts';

export const EXAMPLE_CONTENT = 'https://example.com'; // with scheme so readers open it as a link

// example.com の固定 QR を PNG で返す Hono アプリを作る。
export function createExampleApp(): Hono {
  return new Hono().use(commonHeaders()).get('/v1/example/qr', (c) => pngResponse(c, qrPng(EXAMPLE_CONTENT)));
}
