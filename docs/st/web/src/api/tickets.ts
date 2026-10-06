// Client of the ticket QR API (../../PAGES.md 1): the ticket grant API (JSON), the QR inline grant API and
// URLs of the QR image API. Responses are validated with zod; failures are thrown as ApiError.

import { z } from 'zod';

const TicketCode = z.string().regex(/^\d{14}-[0-9A-HJKMNP-TV-Z]+$/);
const Sig = z.string().regex(/^[A-Za-z0-9_-]{22}$/);
const IssuedAt = z.iso.datetime({ offset: true });

// チケット発行 API（Accept: application/json）の 201。
export const PageTicketSchema = z.object({ ticketCode: TicketCode, issuedAt: IssuedAt, sig: Sig, qrUrl: z.url() });
export type PageTicket = z.infer<typeof PageTicketSchema>;

// QR 同梱発行 API の 201。
export const InlineTicketSchema = z.object({
  ticketCode: TicketCode,
  issuedAt: IssuedAt,
  qr: z.object({ mimeType: z.literal('image/png'), data: z.base64() }),
});
export type InlineTicket = z.infer<typeof InlineTicketSchema>;

export const ApiErrorSchema = z.object({ error: z.object({ code: z.string(), message: z.string() }) });

// SPA のチケット画面の URL パラメータ（#/tickets/{code}?sig=…）。
export const TicketRouteSchema = z.object({ code: TicketCode, sig: Sig });
export type TicketRoute = z.infer<typeof TicketRouteSchema>;

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

// 画面遷移方式（メイン）: チケット発行 API に画像をそのまま送り、署名付きの QR の URL を受け取る。
export function grantForPage(apiBaseUrl: string, file: File): Promise<PageTicket> {
  return post(`${apiBaseUrl}/v1/tickets`, file, PageTicketSchema, { Accept: 'application/json' });
}

// その場表示方式（オプション）: QR 同梱発行 API に画像をそのまま送り、QR（base64）付きの結果を受け取る。
export function grantInline(apiBaseUrl: string, file: File): Promise<InlineTicket> {
  return post(`${apiBaseUrl}/v1/tickets/qr-inline`, file, InlineTicketSchema);
}

// SPA のチケット画面の QR 画像 API の URL を組み立てる（リロード後も URL のパラメータだけから作れる）。
export function qrUrl(apiBaseUrl: string, code: string, sig: string): string {
  return `${apiBaseUrl}/v1/tickets/${encodeURIComponent(code)}/qr?sig=${encodeURIComponent(sig)}`;
}

// フォーム送信方式（オプション）の送信先。fetch は使わず、フォームの action に入れる。
export function grantFormAction(apiBaseUrl: string): string {
  return `${apiBaseUrl}/v1/tickets`;
}

// 画像を FormData の image として POST し、201 を schema で、それ以外をエラー応答として解釈する。
async function post<T>(
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
