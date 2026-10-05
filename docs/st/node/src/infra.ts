// Implementations that talk to the outside world: environment variables, Parameter Store, the image
// analysis server (HTTP client or in-process mock) and log output. The business
// logic in domain.ts only sees the Analyzer / Log ports.

import { AnalyzerError, type Analyzer, type AnalyzerResult, type Log } from './domain.ts';

// =================================================================================================
// Config and salts  (↔ go/internal/config, go/internal/secret)
// =================================================================================================

export type Config = {
  publicBaseUrl: string; // absolute, no trailing slash
  publicOrigin: string; // scheme://host[:port], for CSP
  suffixLength: number;
};

const DEFAULT_SUFFIX_LENGTH = 8;

// 環境変数を読み込んで検証し、Config を返す。
export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const base = (env.PUBLIC_BASE_URL ?? '').replace(/\/+$/, '');
  const url = absoluteUrl('PUBLIC_BASE_URL', base);

  let suffixLength = DEFAULT_SUFFIX_LENGTH;
  if (env.TICKET_SUFFIX_LENGTH) {
    suffixLength = Number(env.TICKET_SUFFIX_LENGTH);
    if (!Number.isInteger(suffixLength) || suffixLength < 1 || suffixLength > 32) {
      throw new Error(`TICKET_SUFFIX_LENGTH must be 1-32, got "${env.TICKET_SUFFIX_LENGTH}"`);
    }
  }

  return { publicBaseUrl: base, publicOrigin: url.origin, suffixLength };
}

// 絶対 URL（http / https）であることを確かめて返す。
function absoluteUrl(name: string, value: string | undefined): URL {
  let url: URL | undefined;
  try {
    url = new URL(value ?? '');
  } catch {}
  if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) {
    throw new Error(`${name} must be an absolute http(s) URL, got "${value ?? ''}"`);
  }
  return url;
}

export type Salts = { current: string; previous?: string };

// Parameter Store の SecureString から salt を取得する（APP_ENV=local のときだけ環境変数 SIGNING_SALT の平文を使う）。
export async function loadSalts(env: NodeJS.ProcessEnv): Promise<Salts> {
  if (env.SIGNING_SALT_PARAMETER_NAME) {
    return JSON.parse(await readParameter(env.SIGNING_SALT_PARAMETER_NAME)) as Salts;
  }
  if (env.APP_ENV === 'local' && env.SIGNING_SALT) {
    return { current: env.SIGNING_SALT };
  }
  throw new Error('SIGNING_SALT_PARAMETER_NAME is not set');
}

// Parameter Store から SecureString を復号して取得する（SDK は Lambda ランタイム同梱のものを使い、バンドルしない）。
async function readParameter(name: string): Promise<string> {
  const { SSMClient, GetParameterCommand } = await import('@aws-sdk/client-ssm');
  const out = await new SSMClient({}).send(new GetParameterCommand({ Name: name, WithDecryption: true }));
  if (!out.Parameter?.Value) throw new Error(`parameter ${name} is empty`);
  return out.Parameter.Value;
}

// =================================================================================================
// Image analysis client  (↔ go/internal/analyzer, DESIGN.md 7, analyzer-stub/DESIGN.md 3)
// =================================================================================================

const DEFAULT_ANALYZER_TIMEOUT_MS = 5000;

// ANALYZER_MODE に応じた画像解析クライアントを返す（mock: その場で valid / http: 解析サーバーに POST）。
export async function newAnalyzer(env: NodeJS.ProcessEnv): Promise<Analyzer> {
  switch (env.ANALYZER_MODE) {
    case 'mock':
      return alwaysValid;
    case 'http': {
      const url = absoluteUrl('ANALYZER_URL', env.ANALYZER_URL).href;
      const timeoutMs = Number(env.ANALYZER_TIMEOUT_MS ?? DEFAULT_ANALYZER_TIMEOUT_MS);
      if (!Number.isInteger(timeoutMs) || timeoutMs < 1)
        throw new Error('ANALYZER_TIMEOUT_MS must be a positive integer');
      return httpAnalyzer({ url, apiKey: await loadAnalyzerApiKey(env), timeoutMs });
    }
    default:
      throw new Error(`unsupported ANALYZER_MODE "${env.ANALYZER_MODE ?? ''}"`);
  }
}

// 常に valid を返す画像解析のモック（通信しない）。
export const alwaysValid: Analyzer = async () => ({ valid: true, reason: 'mock' });

// Parameter Store から解析サーバーの API キーを取得する（APP_ENV=local のときだけ環境変数 ANALYZER_API_KEY の平文を使う）。
async function loadAnalyzerApiKey(env: NodeJS.ProcessEnv): Promise<string> {
  if (env.ANALYZER_API_KEY_PARAMETER_NAME) return readParameter(env.ANALYZER_API_KEY_PARAMETER_NAME);
  if (env.APP_ENV === 'local' && env.ANALYZER_API_KEY) return env.ANALYZER_API_KEY;
  throw new Error('ANALYZER_API_KEY_PARAMETER_NAME is not set');
}

type Attempt = { result: AnalyzerResult } | { error: AnalyzerError; retry: boolean };

// 画像を octet-stream でそのまま POST する HTTP クライアントを作る（5xx・タイムアウト・通信エラーのときだけ1回リトライ）。
export function httpAnalyzer({ url, apiKey, timeoutMs }: { url: string; apiKey: string; timeoutMs: number }): Analyzer {
  const attempt = async (data: Uint8Array): Promise<Attempt> => {
    let res: Response;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/octet-stream', 'x-api-key': apiKey },
        body: new Uint8Array(data),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (err) {
      const timedOut = err instanceof DOMException && err.name === 'TimeoutError';
      return {
        error: new AnalyzerError(timedOut ? 'timeout' : 'upstream', `analyzer request failed: ${err}`),
        retry: true,
      };
    }
    if (!res.ok) {
      return { error: new AnalyzerError('upstream', `analyzer returned ${res.status}`), retry: res.status >= 500 };
    }
    try {
      return { result: parseAnalyzerResponse(await res.json()) };
    } catch (err) {
      const timedOut = err instanceof DOMException && err.name === 'TimeoutError';
      return {
        error: new AnalyzerError(timedOut ? 'timeout' : 'upstream', `bad analyzer response: ${err}`),
        retry: timedOut,
      };
    }
  };

  return async ({ data }) => {
    let out = await attempt(data);
    if ('error' in out && out.retry) out = await attempt(data);
    if ('error' in out) throw out.error;
    return out.result;
  };
}

// 解析サーバーのレスポンス本文を AnalyzerResult にする（仮の形式 {valid, reason}。本物の仕様が決まったらここだけ差し替える）。
function parseAnalyzerResponse(body: unknown): AnalyzerResult {
  const { valid, reason } = (body ?? {}) as { valid?: unknown; reason?: unknown };
  if (typeof valid !== 'boolean') throw new Error('"valid" must be a boolean');
  return { valid, reason: typeof reason === 'string' ? reason : '' };
}

// =================================================================================================
// Logging  (↔ slog JSON in go/internal/app)
// =================================================================================================

// Go の slog（JSON）と同じキーで1行の JSON ログを出す。
export const consoleLog: Log = (level, msg, fields) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), level, msg, ...fields }));
