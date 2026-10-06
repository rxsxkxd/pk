// Business logic of the ticket QR API: the rules shared with the ticket consumer and verifyAndGrant
// (verify a certificate image, then grant a ticket).
// (Format detection and the runtime size limit live in app.ts; which formats are accepted is decided here.)
// No I/O here — external systems are reached through the Verifier and Log ports, implemented in
// infra.ts. Rules are checked against ../testdata, shared with the Go version.

import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

// =================================================================================================
// Verify and grant  (↔ go/internal/ticket/grant.go)
// =================================================================================================

export type Ports = { verifier: Verifier; newTicket: () => Ticket; log: Log };

// Formats iPhone and major Android phones upload as-is (business rule).
const ACCEPTED_IMAGE_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/heic',
  'image/heif',
  'image/avif',
  'image/webp',
]);

// 証明書の画像を検証し（受け付ける形式か → 検証サーバーの判定）、通ったときだけ新しいチケットを与える。
export async function verifyAndGrant(ports: Ports, img: CertificateImage): Promise<Ticket> {
  if (img.data.length === 0) throw badRequest('image is empty');
  if (!img.mimeType || !ACCEPTED_IMAGE_TYPES.has(img.mimeType)) {
    throw unsupportedMediaType('image must be JPEG, PNG, HEIC/HEIF, AVIF or WebP');
  }

  let verdict: Verdict;
  try {
    verdict = await ports.verifier({ data: img.data, mimeType: img.mimeType });
  } catch (err) {
    if (err instanceof VerifierError && err.kind === 'timeout') throw analysisTimeout();
    ports.log('ERROR', 'image analysis failed', { error: String(err) });
    throw analysisUpstream();
  }
  if (!verdict.valid) {
    ports.log('INFO', 'image rejected', { reason: verdict.reason });
    throw certificateRejected('image was rejected');
  }

  const t = ports.newTicket();
  ports.log('INFO', 'ticket issued', { ticketCode: t.code, issuedAt: t.issuedAt, analysisReason: verdict.reason });
  return t;
}

// =================================================================================================
// Ticket code: {YYYYMMDDHHmmss}-{suffix}  (↔ go/internal/ticket/code.go, DESIGN.md 4)
// =================================================================================================

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford Base32 (no I, L, O, U)

// Formats the time a ticket is granted (issuedAt) in JST. hourCycle h23 gives "00" (not "24") at midnight. Pure, so bundles that
// never grant tickets (exampleqr) drop it.
const JST = /* @__PURE__ */ new Intl.DateTimeFormat('en-US', {
  timeZone: 'Asia/Tokyo',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hourCycle: 'h23',
});

export type Ticket = { code: string; issuedAt: string }; // issuedAt: RFC 3339 in JST

// JST の発行日時と乱数 suffix からチケットコードを生成する（時刻と乱数源はテスト用に差し替え可能）。
export function generateTicket(
  suffixLength: number,
  now: Date = new Date(),
  random: (size: number) => Uint8Array = randomBytes,
): Ticket {
  const bytes = random(suffixLength);
  if (bytes.length < suffixLength) throw new Error('read random: short read');
  // 256 is a multiple of 32, so the low 5 bits of each byte are uniform.
  const suffix = Array.from(bytes.subarray(0, suffixLength), (b) => ALPHABET[b & 31]).join('');

  const part = Object.fromEntries(JST.formatToParts(now).map((p) => [p.type, p.value]));
  const { year: y, month: mo, day: d, hour: h, minute: mi, second: s } = part;
  return { code: `${y}${mo}${d}${h}${mi}${s}-${suffix}`, issuedAt: `${y}-${mo}-${d}T${h}:${mi}:${s}+09:00` };
}

// =================================================================================================
// Signer: first 22 chars of base64url(HMAC-SHA256(salt, code))  (↔ go/internal/signer, DESIGN.md 5.5)
// =================================================================================================

const SIG_LENGTH = 22;

export type Signer = { sign(ticketCode: string): string; verify(ticketCode: string, sig: string): boolean };

// 現行（と移行期間中は旧）の salt で、sig の生成と照合を行う Signer を作る。
export function newSigner(current: string, previous?: string): Signer {
  if (!current) throw new Error('signing salt is empty');
  const keys = previous ? [current, previous] : [current];
  const sign = (key: string, code: string) =>
    createHmac('sha256', key).update(code).digest('base64url').slice(0, SIG_LENGTH);

  return {
    sign: (code) => sign(current, code),
    verify: (code, sig) => {
      const given = Buffer.from(sig);
      if (sig.length !== SIG_LENGTH || given.length !== SIG_LENGTH) return false;
      return keys.some((k) => timingSafeEqual(Buffer.from(sign(k, code)), given));
    },
  };
}

// =================================================================================================
// Ports implemented in infra.ts  (↔ go/internal/ticket/verifier.go; implemented by go/internal/analyzer)
// =================================================================================================

// The uploaded image of a certificate, exactly as received, with the format detected by the HTTP layer
// (undefined if unknown).
export type CertificateImage = { data: Uint8Array; mimeType: string | undefined };

// Verification by the image analysis server: POST application/octet-stream with the bytes as-is (DESIGN.md 7).
export type Verdict = { valid: boolean; reason: string };
export type Verifier = (img: { data: Uint8Array; mimeType: string }) => Promise<Verdict>;

// 検証サーバーの通信失敗（502）/ タイムアウト（504）を表すエラー（検証のクライアントが投げる）。
export class VerifierError extends Error {
  kind: 'upstream' | 'timeout';
  constructor(kind: 'upstream' | 'timeout', message: string) {
    super(message);
    this.kind = kind;
  }
}

export type Log = (level: 'INFO' | 'ERROR', msg: string, fields?: Record<string, unknown>) => void;

// =================================================================================================
// Errors  (↔ go/internal/ticket/errors.go and go/internal/httpapi/errors.go)
// =================================================================================================

// HTTP ステータス・エラーコード・メッセージを持つ、API のエラーレスポンスに対応する例外。
export class AppError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

// 各エラーの AppError を作る（メッセージは Go 版と同じ）。
export const badRequest = (msg: string) => new AppError(400, 'BAD_REQUEST', msg);
export const forbidden = () => new AppError(403, 'FORBIDDEN', 'invalid signature');
export const notFound = () => new AppError(404, 'NOT_FOUND', 'route not found');
export const payloadTooLarge = (msg: string) => new AppError(413, 'PAYLOAD_TOO_LARGE', msg);
export const unsupportedMediaType = (msg: string) => new AppError(415, 'UNSUPPORTED_MEDIA_TYPE', msg);
export const certificateRejected = (msg: string) => new AppError(422, 'IMAGE_INVALID', msg);
export const analysisUpstream = () => new AppError(502, 'ANALYSIS_UPSTREAM_ERROR', 'image analysis failed');
export const analysisTimeout = () => new AppError(504, 'ANALYSIS_TIMEOUT', 'image analysis timed out');
export const internal = () => new AppError(500, 'INTERNAL_ERROR', 'internal error');
