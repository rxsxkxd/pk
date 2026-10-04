// Implementations that talk to the outside world: environment variables, Secrets Manager, template
// files, the QR library, the image analysis server (mock for now) and log output. The business
// logic in domain.ts only sees the Analyzer / Log ports.

import { readFileSync } from 'node:fs';
import { correction, generate } from 'lean-qr';
import { toPngBuffer } from 'lean-qr/extras/node_export';
import type { Analyzer, Log } from './domain.ts';

// =================================================================================================
// Config and salts  (↔ go/internal/config, go/internal/secret)
// =================================================================================================

export type Config = {
  publicBaseUrl: string; // absolute, no trailing slash
  publicOrigin: string; // scheme://host[:port], for CSP
  suffixLength: number;
  analyzerMode: string;
};

const DEFAULT_SUFFIX_LENGTH = 8;

// 環境変数を読み込んで検証し、Config を返す。
export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const base = (env.PUBLIC_BASE_URL ?? '').replace(/\/+$/, '');
  let url: URL | undefined;
  try {
    url = new URL(base);
  } catch {}
  if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) {
    throw new Error(`PUBLIC_BASE_URL must be an absolute http(s) URL, got "${base}"`);
  }

  let suffixLength = DEFAULT_SUFFIX_LENGTH;
  if (env.TICKET_SUFFIX_LENGTH) {
    suffixLength = Number(env.TICKET_SUFFIX_LENGTH);
    if (!Number.isInteger(suffixLength) || suffixLength < 1 || suffixLength > 32) {
      throw new Error(`TICKET_SUFFIX_LENGTH must be 1-32, got "${env.TICKET_SUFFIX_LENGTH}"`);
    }
  }

  return { publicBaseUrl: base, publicOrigin: url.origin, suffixLength, analyzerMode: env.ANALYZER_MODE ?? '' };
}

export type Salts = { current: string; previous?: string };

// Secrets Manager から salt を取得する（APP_ENV=local のときだけ環境変数 SIGNING_SALT の平文を使う）。
export async function loadSalts(env: NodeJS.ProcessEnv): Promise<Salts> {
  if (env.SIGNING_SALT_SECRET_ID) {
    // Provided by the Lambda runtime; not bundled.
    const { SecretsManagerClient, GetSecretValueCommand } = await import('@aws-sdk/client-secrets-manager');
    const out = await new SecretsManagerClient({}).send(
      new GetSecretValueCommand({ SecretId: env.SIGNING_SALT_SECRET_ID }),
    );
    return JSON.parse(out.SecretString ?? '{}') as Salts;
  }
  if (env.APP_ENV === 'local' && env.SIGNING_SALT) {
    return { current: env.SIGNING_SALT };
  }
  throw new Error('SIGNING_SALT_SECRET_ID is not set');
}

// =================================================================================================
// Image analysis client  (↔ go/internal/analyzer)
// Endpoint, auth and response format are not decided yet, so only a mock exists.
// =================================================================================================

// 常に valid を返す画像解析のモック。
export const alwaysValid: Analyzer = async () => ({ valid: true, reason: 'mock' });

// ANALYZER_MODE に応じた画像解析クライアントを返す（現状は mock のみ）。
export function newAnalyzer(mode: string): Analyzer {
  if (mode === 'mock') return alwaysValid;
  throw new Error(`unsupported ANALYZER_MODE "${mode}"`);
}

// =================================================================================================
// QR  (↔ go/internal/qr)
// =================================================================================================

const QR_MAX_PX = 256;
const QUIET_ZONE = 4;

// テキストを誤り訂正 M・余白4モジュールの QR PNG にする（256px 以内に収まる最大の整数倍。NODE.md 3）。
export function qrPng(text: string): Buffer {
  const code = generate(text, { minCorrectionLevel: correction.M, maxCorrectionLevel: correction.M });
  const scale = Math.max(1, Math.floor(QR_MAX_PX / (code.size + 2 * QUIET_ZONE)));
  const png = toPngBuffer(code, { on: [0, 0, 0], off: [255, 255, 255], pad: QUIET_ZONE, scale });
  return Buffer.from(png.buffer, png.byteOffset, png.byteLength);
}

// =================================================================================================
// Views: shared ../templates  (↔ go/internal/view)
// =================================================================================================

// HTML の特殊文字（& < > " '）を数値文字参照にエスケープする。
const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

export type Views = {
  ticket(ticketCode: string, qrUrl: string): string;
  error(code: string, message: string): string;
};

// 共通テンプレートを読み込み、{{.Field}} 以外の構文があれば読み込み時にエラーにする。
export function loadViews(dir: string): Views {
  const load = (name: string, fields: string[]) => {
    const tpl = readFileSync(`${dir.replace(/\/+$/, '')}/${name}`, 'utf8');
    for (const m of tpl.matchAll(/\{\{(.*?)\}\}/g)) {
      const field = /^\.(\w+)$/.exec(m[1])?.[1];
      if (!field || !fields.includes(field)) throw new Error(`${name}: unsupported template action ${m[0]}`);
    }
    return (data: Record<string, string>) => tpl.replace(/\{\{\.(\w+)\}\}/g, (_, k: string) => escapeHtml(data[k]));
  };
  const ticket = load('ticket.html', ['TicketCode', 'QRURL']);
  const error = load('error.html', ['Code', 'Message']);
  return {
    ticket: (ticketCode, qrUrl) => ticket({ TicketCode: ticketCode, QRURL: qrUrl }),
    error: (code, message) => error({ Code: code, Message: message }),
  };
}

// =================================================================================================
// Logging  (↔ slog JSON in go/internal/app)
// =================================================================================================

// Go の slog（JSON）と同じキーで1行の JSON ログを出す。
export const consoleLog: Log = (level, msg, fields) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), level, msg, ...fields }));
