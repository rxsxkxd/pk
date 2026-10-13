// その場表示方式（オプション）の API: QR 同梱発行 API（QR を base64 で受け取る）。

import * as v from 'valibot';
import { IssuedAt, postImage, TicketCode } from '../../api/client.ts';

// QR 同梱発行 API の 201。
export const InlineTicketSchema = v.object({
  ticketCode: TicketCode,
  issuedAt: IssuedAt,
  qr: v.object({ mimeType: v.literal('image/png'), data: v.pipe(v.string(), v.base64()) }),
});
export type InlineTicket = v.InferOutput<typeof InlineTicketSchema>;

// QR 同梱発行 API に画像をそのまま送り、QR（base64）付きの結果を受け取る。
export function grantInline(apiBaseUrl: string, file: File): Promise<InlineTicket> {
  return postImage(`${apiBaseUrl}/v1/tickets/qr-inline`, file, InlineTicketSchema);
}
