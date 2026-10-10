// 画面遷移方式（メイン）の API: チケット発行 API（JSON）と、SPA のチケット画面が使う QR 画像 API の URL。

import { z } from 'zod';
import { IssuedAt, postImage, Sig, TicketCode } from '../../api/client.ts';

// チケット発行 API（Accept: application/json）の 201。
export const PageTicketSchema = z.object({ ticketCode: TicketCode, issuedAt: IssuedAt, sig: Sig, qrUrl: z.url() });
export type PageTicket = z.infer<typeof PageTicketSchema>;

// SPA のチケット画面の URL パラメータ（#/tickets/{code}?sig=…）。
export const TicketRouteSchema = z.object({ code: TicketCode, sig: Sig });
export type TicketRoute = z.infer<typeof TicketRouteSchema>;

// チケット発行 API に画像をそのまま送り、署名付きの QR の URL を受け取る。
export function grantForPage(apiBaseUrl: string, file: File): Promise<PageTicket> {
  return postImage(`${apiBaseUrl}/v1/tickets`, file, PageTicketSchema, { Accept: 'application/json' });
}

// SPA のチケット画面の QR 画像 API の URL を組み立てる（リロード後も URL のパラメータだけから作れる）。
export function qrUrl(apiBaseUrl: string, code: string, sig: string): string {
  return `${apiBaseUrl}/v1/tickets/${encodeURIComponent(code)}/qr?sig=${encodeURIComponent(sig)}`;
}
