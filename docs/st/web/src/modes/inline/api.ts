// その場表示方式（オプション）の API: QR 同梱発行 API（QR を base64 で受け取る）。

import { z } from 'zod';
import { IssuedAt, postImage, TicketCode } from '../../api/client.ts';

// QR 同梱発行 API の 201。
export const InlineTicketSchema = z.object({
  ticketCode: TicketCode,
  issuedAt: IssuedAt,
  qr: z.object({ mimeType: z.literal('image/png'), data: z.base64() }),
});
export type InlineTicket = z.infer<typeof InlineTicketSchema>;

// QR 同梱発行 API に画像をそのまま送り、QR（base64）付きの結果を受け取る。
export function grantInline(apiBaseUrl: string, file: File): Promise<InlineTicket> {
  return postImage(`${apiBaseUrl}/v1/tickets/qr-inline`, file, InlineTicketSchema);
}
