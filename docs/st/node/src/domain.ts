// Business logic of the ticket QR API: the rules shared with the ticket consumer and the issue flow.
// No I/O here — external systems are reached through the Analyzer and Log ports, implemented in
// infra.ts. Rules are checked against ../testdata, shared with the Go version.

import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

// =================================================================================================
// Issue flow  (↔ go/internal/usecase/issue.go)
// =================================================================================================

export type IssuePorts = { analyzer: Analyzer; newTicket: () => Ticket; log: Log };

// 画像を検証して解析サーバーに問い合わせ、valid のときだけチケットコードを採番する。
export async function issueTicket(ports: IssuePorts, image: Uint8Array): Promise<Ticket> {
  const mimeType = validateImage(image);

  let res: AnalyzerResult;
  try {
    res = await ports.analyzer({ data: image, mimeType });
  } catch (err) {
    if (err instanceof AnalyzerError && err.kind === 'timeout') throw analysisTimeout();
    ports.log('ERROR', 'image analysis failed', { error: String(err) });
    throw analysisUpstream();
  }
  if (!res.valid) {
    ports.log('INFO', 'image rejected', { reason: res.reason });
    throw imageInvalid('image was rejected');
  }

  const t = ports.newTicket();
  ports.log('INFO', 'ticket issued', { ticketCode: t.code, issuedAt: t.issuedAt, analysisReason: res.reason });
  return t;
}

// =================================================================================================
// Ticket code: {YYYYMMDDHHmmss}-{suffix}  (↔ go/internal/ticketcode, DESIGN.md 4)
// =================================================================================================

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford Base32 (no I, L, O, U)
const JST_OFFSET_MS = 9 * 60 * 60 * 1000; // fixed offset; no tz database needed

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

  const jst = new Date(now.getTime() + JST_OFFSET_MS);
  const p = (n: number) => String(n).padStart(2, '0');
  const [y, mo, d, h, mi, s] = [
    String(jst.getUTCFullYear()),
    p(jst.getUTCMonth() + 1),
    p(jst.getUTCDate()),
    p(jst.getUTCHours()),
    p(jst.getUTCMinutes()),
    p(jst.getUTCSeconds()),
  ];
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
// Image check  (↔ go/internal/imageinput)
// =================================================================================================

export const MAX_IMAGE_BYTES = 4 << 20;

const SIGNATURES: ReadonlyArray<readonly [string, readonly number[]]> = [
  ['image/jpeg', [0xff, 0xd8, 0xff]],
  ['image/png', [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]],
];

// サイズ上限とマジックバイトで画像を検証し、判定した MIME タイプを返す。
export function validateImage(data: Uint8Array): string {
  if (data.length === 0) throw badRequest('image is empty');
  if (data.length > MAX_IMAGE_BYTES) throw payloadTooLarge(`image must be ${MAX_IMAGE_BYTES} bytes or less`);
  for (const [mime, magic] of SIGNATURES) {
    if (magic.every((b, i) => data[i] === b)) return mime;
  }
  throw unsupportedMediaType('image must be JPEG or PNG');
}

// =================================================================================================
// Ports implemented in infra.ts  (↔ go/internal/analyzer, slog)
// =================================================================================================

// Image analysis: POST application/octet-stream with the uploaded bytes as-is (DESIGN.md 7).
export type AnalyzerResult = { valid: boolean; reason: string };
export type Analyzer = (image: { data: Uint8Array; mimeType: string }) => Promise<AnalyzerResult>;

// 解析サーバーの通信失敗（502）/ タイムアウト（504）を表すエラー（解析クライアントが投げる）。
export class AnalyzerError extends Error {
  kind: 'upstream' | 'timeout';
  constructor(kind: 'upstream' | 'timeout', message: string) {
    super(message);
    this.kind = kind;
  }
}

export type Log = (level: 'INFO' | 'ERROR', msg: string, fields?: Record<string, unknown>) => void;

// =================================================================================================
// Errors  (↔ go/internal/apperr)
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
export const imageInvalid = (msg: string) => new AppError(422, 'IMAGE_INVALID', msg);
export const analysisUpstream = () => new AppError(502, 'ANALYSIS_UPSTREAM_ERROR', 'image analysis failed');
export const analysisTimeout = () => new AppError(504, 'ANALYSIS_TIMEOUT', 'image analysis timed out');
export const internal = () => new AppError(500, 'INTERNAL_ERROR', 'internal error');
