// Implementations that talk to the outside world: environment variables, Parameter Store, the image
// analysis server (HTTP client or in-process mock) and log output. The business
// logic in domain.ts only sees the Verifier / Log ports.

import { VerifierError, type Verifier, type Verdict, type Log } from './domain.ts';

// =================================================================================================
// Config and salts  (↔ go/internal/config)
// =================================================================================================

export type Config = {
  publicBaseUrl: string; // absolute, no trailing slash
  publicOrigin: string; // scheme://host[:port], for CSP
};

// 環境変数を読み込んで検証し、Config を返す。
export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const base = (env.PUBLIC_BASE_URL ?? '').replace(/\/+$/, '');
  const url = absoluteUrl('PUBLIC_BASE_URL', base);

  return { publicBaseUrl: base, publicOrigin: url.origin };
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

// チケットコードの末尾の固定文字列を、Parameter Store の String（TICKET_CODE_SUFFIX_PARAMETER_NAME）から取得する。
// 秘密ではないので、環境変数 TICKET_CODE_SUFFIX で直接渡してもよい（ローカル実行・E2E）。値の形は generateTicket が確かめる。
export async function loadTicketCodeSuffix(env: NodeJS.ProcessEnv): Promise<string> {
  if (env.TICKET_CODE_SUFFIX_PARAMETER_NAME) return readParameter(env.TICKET_CODE_SUFFIX_PARAMETER_NAME);
  if (env.TICKET_CODE_SUFFIX) return env.TICKET_CODE_SUFFIX;
  throw new Error('TICKET_CODE_SUFFIX_PARAMETER_NAME is not set');
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

// ANALYZER_MODE に応じた画像解析クライアントを返す（mock: その場で PASS / http: 解析サーバーに POST）。
export async function newAnalyzer(env: NodeJS.ProcessEnv, log: Log = consoleLog): Promise<Verifier> {
  switch (env.ANALYZER_MODE) {
    case 'mock':
      return alwaysPass;
    case 'http': {
      const url = absoluteUrl('ANALYZER_URL', env.ANALYZER_URL).href;
      const timeoutMs = Number(env.ANALYZER_TIMEOUT_MS ?? DEFAULT_ANALYZER_TIMEOUT_MS);
      if (!Number.isInteger(timeoutMs) || timeoutMs < 1)
        throw new Error('ANALYZER_TIMEOUT_MS must be a positive integer');
      return httpAnalyzer({ url, apiKey: await loadAnalyzerApiKey(env), timeoutMs, log });
    }
    default:
      throw new Error(`unsupported ANALYZER_MODE "${env.ANALYZER_MODE ?? ''}"`);
  }
}

// 常に PASS を返す画像解析のモック（通信しない）。
export const alwaysPass: Verifier = async () => ({ result: 'PASS' });

// Parameter Store から解析サーバーの API キーを取得する（APP_ENV=local のときだけ環境変数 ANALYZER_API_KEY の平文を使う）。
// API キーは任意。どちらも無ければ undefined で、x-api-key を付けずに送る（例: VPC 内でセキュリティグループだけで許可する解析サーバー）。
async function loadAnalyzerApiKey(env: NodeJS.ProcessEnv): Promise<string | undefined> {
  if (env.ANALYZER_API_KEY_PARAMETER_NAME) return readParameter(env.ANALYZER_API_KEY_PARAMETER_NAME);
  if (env.APP_ENV === 'local' && env.ANALYZER_API_KEY) return env.ANALYZER_API_KEY;
  return undefined;
}

type Attempt = { result: Verdict } | { error: VerifierError; retry: boolean };

// 画像を octet-stream でそのまま POST する HTTP クライアントを作る（5xx・タイムアウト・通信エラーのときだけ1回リトライ）。
// 応答の本文は、2xx でもそれ以外でも、JSON として読まずにそのままログに出す（"analyzer response"）。そのあと result だけを読む。
export function httpAnalyzer({
  url,
  apiKey,
  timeoutMs,
  log = consoleLog,
}: {
  url: string;
  apiKey?: string;
  timeoutMs: number;
  log?: Log;
}): Verifier {
  const headers: Record<string, string> = { 'content-type': 'application/octet-stream' };
  if (apiKey) headers['x-api-key'] = apiKey;
  const attempt = async (data: Uint8Array): Promise<Attempt> => {
    let res: Response;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers,
        body: new Uint8Array(data),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (err) {
      const timedOut = err instanceof DOMException && err.name === 'TimeoutError';
      return {
        error: new VerifierError(timedOut ? 'timeout' : 'upstream', `analyzer request failed: ${err}`),
        retry: true,
      };
    }
    let text: string;
    try {
      text = await res.text();
    } catch (err) {
      const timedOut = err instanceof DOMException && err.name === 'TimeoutError';
      return {
        error: new VerifierError(timedOut ? 'timeout' : 'upstream', `analyzer response read failed: ${err}`),
        retry: true,
      };
    }
    log(res.ok ? 'INFO' : 'WARN', 'analyzer response', { status: res.status, body: text });
    if (!res.ok) {
      return { error: new VerifierError('upstream', `analyzer returned ${res.status}`), retry: res.status >= 500 };
    }
    try {
      return { result: parseAnalyzerResponse(JSON.parse(text)) };
    } catch (err) {
      return { error: new VerifierError('upstream', `bad analyzer response: ${err}`), retry: false };
    }
  };

  return async ({ data }) => {
    let out = await attempt(data);
    if ('error' in out && out.retry) out = await attempt(data);
    if ('error' in out) throw out.error;
    return out.result;
  };
}

// 解析サーバーのレスポンス本文（confidence・detected・reason・result・status）を Verdict にする。API が見るのは result だけ。
function parseAnalyzerResponse(body: unknown): Verdict {
  const { result } = (body ?? {}) as { result?: unknown };
  if (result !== 'PASS' && result !== 'REJECT' && result !== 'RETRY') {
    throw new Error(`"result" must be PASS, REJECT or RETRY, got ${JSON.stringify(result)}`);
  }
  return { result };
}

// =================================================================================================
// Logging  (↔ slog JSON in go/cmd/ticketqr/wire.go)
// =================================================================================================

// Go の slog（JSON）と同じキーで1行の JSON ログを出す。
export const consoleLog: Log = (level, msg, fields) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), level, msg, ...fields }));
