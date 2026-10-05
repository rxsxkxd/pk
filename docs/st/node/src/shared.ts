// HTTP helpers shared by the ticket app (app.ts) and the example app (example.ts): common response
// headers and QR PNG rendering. Keeps the example package free of the ticket code and its libraries.

import type { Context, MiddlewareHandler } from 'hono';
import { correction, generate } from 'lean-qr';
import { toPngBuffer } from 'lean-qr/extras/node_export';

// すべてのレスポンスに共通ヘッダー（キャッシュ禁止・nosniff・Referrer-Policy、指定があれば CSP）を付ける。
export const commonHeaders =
  (csp?: string): MiddlewareHandler =>
  async (c, next) => {
    await next();
    c.header('Cache-Control', 'no-store');
    c.header('X-Content-Type-Options', 'nosniff');
    c.header('Referrer-Policy', 'no-referrer');
    if (csp) c.header('Content-Security-Policy', csp);
  };

// PNG の 200 レスポンスを作る（Lambda では image/png をアダプターが base64 にする）。
export function pngResponse(c: Context, png: Buffer): Response {
  return c.body(new Uint8Array(png), 200, { 'Content-Type': 'image/png' });
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
