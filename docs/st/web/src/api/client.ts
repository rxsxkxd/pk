// Shared part of the ticket QR API client (../../PAGES.md 1): the schemas every grant mode uses, ApiError and
// the image POST. Each grant mode has its own endpoints and response schemas in src/modes/<mode>/api.ts.
// Responses are validated with valibot; failures are thrown as ApiError.

import * as v from 'valibot';

// {YYYYMMDDHHmmss}{UUIDv4 のハイフンなし小文字16進32桁}{固定文字列（英数字1〜32文字）}（../../DESIGN.md 4章）
export const TicketCode = v.pipe(v.string(), v.regex(/^\d{14}[0-9a-f]{32}[A-Za-z0-9]{1,32}$/));
export const Sig = v.pipe(v.string(), v.regex(/^[A-Za-z0-9_-]{22}$/));
// RFC 3339 with an offset (the API sends +09:00).
export const IssuedAt = v.pipe(v.string(), v.isoTimestamp());

export const ApiErrorSchema = v.object({ error: v.object({ code: v.string(), message: v.string() }) });

// API Gateway gives up after 29s; wait slightly longer so its 504 arrives first.
export const TIMEOUT_MS = 30_000;

// API のエラー。code は API のエラーコード、または NETWORK（通信失敗・タイムアウト）/ UNEXPECTED（予期しない応答）。
export class ApiError extends Error {
  code: string;
  status: number | undefined;
  constructor(code: string, message: string, status?: number) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

// 画像を FormData の image として POST し、201 を schema で、それ以外をエラー応答として解釈する。
export async function postImage<T>(
  url: string,
  file: File,
  schema: v.GenericSchema<unknown, T>,
  headers: Record<string, string> = {},
): Promise<T> {
  const body = new FormData();
  body.append('image', file); // Content-Type (with the boundary) is set by the browser.

  // AbortSignal.timeout() is not used: iOS 16 / Chrome 124 and later only (DESIGN.md 2.4). The timer covers
  // the whole exchange, reading the response body included.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  let res: Response;
  let json: unknown;
  try {
    try {
      res = await fetch(url, { method: 'POST', body, headers, signal: controller.signal });
    } catch {
      throw new ApiError('NETWORK', 'request failed');
    }
    json = await res.json().catch(() => undefined);
  } finally {
    clearTimeout(timer);
  }

  if (res.status === 201) {
    const ok = v.safeParse(schema, json);
    if (ok.success) return ok.output;
  } else {
    const err = v.safeParse(ApiErrorSchema, json);
    if (err.success) throw new ApiError(err.output.error.code, err.output.error.message, res.status);
  }
  throw new ApiError('UNEXPECTED', `unexpected response (HTTP ${res.status})`, res.status);
}
