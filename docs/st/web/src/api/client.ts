// Shared part of the ticket QR API client (../../PAGES.md 1): the schemas every grant mode uses, ApiError and
// the image POST. Each grant mode has its own endpoints and response schemas in src/modes/<mode>/api.ts.
// Responses are validated with zod; failures are thrown as ApiError.

import { z } from 'zod';

// {YYYYMMDDHHmmss}{UUIDv4 のハイフンなし小文字16進32桁}{固定文字列（英数字1〜32文字）}（../../DESIGN.md 4章）
export const TicketCode = z.string().regex(/^\d{14}[0-9a-f]{32}[A-Za-z0-9]{1,32}$/);
export const Sig = z.string().regex(/^[A-Za-z0-9_-]{22}$/);
export const IssuedAt = z.iso.datetime({ offset: true });

export const ApiErrorSchema = z.object({ error: z.object({ code: z.string(), message: z.string() }) });

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
  schema: z.ZodType<T>,
  headers: Record<string, string> = {},
): Promise<T> {
  const body = new FormData();
  body.append('image', file); // Content-Type (with the boundary) is set by the browser.

  let res: Response;
  try {
    res = await fetch(url, { method: 'POST', body, headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch {
    throw new ApiError('NETWORK', 'request failed');
  }
  const json: unknown = await res.json().catch(() => undefined);

  if (res.status === 201) {
    const ok = schema.safeParse(json);
    if (ok.success) return ok.data;
  } else {
    const err = ApiErrorSchema.safeParse(json);
    if (err.success) throw new ApiError(err.data.error.code, err.data.error.message, res.status);
  }
  throw new ApiError('UNEXPECTED', `unexpected response (HTTP ${res.status})`, res.status);
}
