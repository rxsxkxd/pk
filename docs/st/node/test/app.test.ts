import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, describe, test } from 'node:test';
import { handle } from '@hono/aws-lambda';
import type { APIGatewayProxyEventV2 as Event, APIGatewayProxyStructuredResultV2 as Result } from 'aws-lambda';
import { correction, generate } from 'lean-qr';
import { createApp, type Deps } from '../src/app.ts';
import { MAX_IMAGE_BYTES } from '../src/image.ts';
import { createExampleApp } from '../src/example.ts';
import { qrPng } from '../src/shared.ts';
import { AnalyzerError, generateTicket, newSigner, type Analyzer, type Log } from '../src/domain.ts';
import { alwaysValid, httpAnalyzer, loadConfig, newAnalyzer } from '../src/infra.ts';

const root = new URL('../../', import.meta.url);
const vectors = (name: string) => JSON.parse(readFileSync(new URL(`testdata/${name}`, root), 'utf8'));

// Real 32x32 images in each accepted format (../testdata/images, shared with Go).
const image = (name: string) => new Uint8Array(readFileSync(new URL(`testdata/images/${name}`, root)));
const JPEG = image('photo.jpg');
const PNG = image('photo.png');
const PNG_MAGIC = PNG.subarray(0, 8);
const CODE_RE = /^\d{14}-[0-9A-HJKMNP-TV-Z]{8}$/;
const BASE = 'https://api.example.com';

const ISSUE_INLINE = '/v1/tickets/qr-inline';
const ISSUE = '/v1/tickets';

// ---------------------------------------------------------------- helpers
// Requests go through @hono/aws-lambda, so the tests also cover the Lambda event conversion.

type LambdaHandler = (event: Event) => Promise<Result>;

function newRoute(analyzer: Analyzer = alwaysValid, log: Log = () => {}) {
  const deps: Deps = {
    config: { publicBaseUrl: BASE, publicOrigin: BASE, suffixLength: 8 },
    analyzer,
    signer: newSigner('test-salt'),
    newTicket: () => generateTicket(8),
    log,
  };
  return { deps, handle: handle(createApp(deps)) as LambdaHandler };
}

type EventInit = {
  method?: string;
  path: string;
  query?: string;
  headers?: Record<string, string>;
  body?: string;
  base64?: boolean;
};

// API Gateway HTTP API (payload v2) event with only the fields the adapter reads.
const event = ({ method = 'GET', path, query = '', headers = {}, body, base64 = false }: EventInit) =>
  ({
    version: '2.0',
    routeKey: '$default',
    rawPath: path,
    rawQueryString: query,
    headers: { host: 'api.example.com', ...headers },
    body,
    isBase64Encoded: base64,
    requestContext: { requestId: 'test', domainName: 'api.example.com', http: { method, path } },
  }) as unknown as Event;

async function formEvent(path: string, field: string, data: Uint8Array): Promise<Event> {
  const fd = new FormData();
  fd.append(field, new Blob([new Uint8Array(data)]), 'upload.jpg');
  const req = new Request('http://local/', { method: 'POST', body: fd });
  const body = Buffer.from(await req.arrayBuffer()).toString('base64');
  return event({
    method: 'POST',
    path,
    headers: { 'content-type': req.headers.get('content-type')! },
    body,
    base64: true,
  });
}

// withContentType rewrites the Content-Type of a form event; %s in format is replaced by its boundary.
async function withContentType(ev: Promise<Event>, format: string): Promise<Event> {
  const e = (await ev) as unknown as { headers: Record<string, string> };
  const boundary = /boundary=(\S+)/.exec(e.headers['content-type'])![1];
  e.headers = { ...e.headers, 'content-type': format.replaceAll('%s', boundary) };
  return e as unknown as Event;
}

// brokenAfterImage is a valid image part followed by a part whose headers never end.
async function brokenAfterImage(path: string): Promise<Event> {
  const e = (await formEvent(path, 'image', JPEG)) as unknown as { headers: Record<string, string>; body: string };
  const boundary = /boundary=(\S+)/.exec(e.headers['content-type'])![1];
  const body = Buffer.from(e.body, 'base64').toString('latin1');
  const closing = `--${boundary}--\r\n`;
  assert.ok(body.endsWith(closing));
  e.body = Buffer.from(`${body.slice(0, -closing.length)}--${boundary}\r\nX-Broken`, 'latin1').toString('base64');
  return e as unknown as Event;
}

// rawEvent builds a POST whose body is sent as-is (for non-multipart and malformed bodies).
const rawEvent = (path: string, contentType: string, body: string) =>
  event({ method: 'POST', path, headers: { 'content-type': contentType }, body });

const signedGet = (resource: 'view' | 'qr', code: string, sig: string) =>
  event({ path: `/v1/tickets/${encodeURIComponent(code)}/${resource}`, query: `sig=${encodeURIComponent(sig)}` });

const header = (res: Result, name: string) =>
  String(Object.entries(res.headers ?? {}).find(([k]) => k.toLowerCase() === name.toLowerCase())?.[1] ?? '');
const errorCode = (res: Result) => JSON.parse(res.body ?? '').error.code as string;
const stub =
  (result: Partial<{ valid: boolean; reason: string }>, err?: Error): Analyzer =>
  async () => {
    if (err) throw err;
    return { valid: true, reason: '', ...result };
  };

function assertCommonHeaders(res: Result) {
  assert.equal(header(res, 'Cache-Control'), 'no-store');
  assert.equal(header(res, 'X-Content-Type-Options'), 'nosniff');
}

// PNG IHDR width/height are big-endian uint32 at bytes 16 and 20.
const pngSize = (png: Buffer) => [png.readUInt32BE(16), png.readUInt32BE(20)];

// ---------------------------------------------------------------- shared test vectors (same as Go)

describe('ticket code', () => {
  for (const c of vectors('ticketcode.json').cases) {
    test(c.expected, () => {
      const t = generateTicket(c.suffixLength, new Date(c.now), () => Buffer.from(c.random, 'hex'));
      assert.equal(t.code, c.expected);
      assert.match(t.issuedAt, /\+09:00$/);
      assert.equal(t.issuedAt.slice(0, 19).replace(/\D/g, ''), c.expected.slice(0, 14));
    });
  }

  test('random shape and uniqueness', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 1000; i++) {
      const { code } = generateTicket(8);
      assert.match(code, CODE_RE);
      assert.ok(!seen.has(code), `duplicate ${code}`);
      seen.add(code);
    }
  });

  test('short random source fails', () => {
    assert.throws(() => generateTicket(8, new Date(), () => Uint8Array.of(1, 2)));
  });
});

describe('signer', () => {
  for (const c of vectors('signature.json').cases) {
    test(c.ticketCode, () => {
      const s = newSigner(c.salt);
      assert.equal(s.sign(c.ticketCode), c.sig);
      assert.ok(s.verify(c.ticketCode, c.sig));
    });
  }

  test('verify', () => {
    const code = '20261001194300-7K3QX9MZ';
    const old = newSigner('old-salt');
    const cur = newSigner('new-salt');
    const rotating = newSigner('new-salt', 'old-salt');
    assert.ok(rotating.verify(code, cur.sign(code)));
    assert.ok(rotating.verify(code, old.sign(code)), 'previous salt during rotation');
    assert.ok(!cur.verify(code, old.sign(code)), 'previous salt after rotation');
    assert.ok(!cur.verify('20261001000000-00000000', cur.sign(code)));
    assert.ok(!cur.verify(code, ''));
    assert.ok(!cur.verify(code, cur.sign(code).slice(0, 21)));
    assert.ok(!cur.verify(code, 'あ'.repeat(22)), 'multi-byte input of the right length');
  });

  test('empty salt is rejected', () => {
    assert.throws(() => newSigner(''));
  });
});

describe('config', () => {
  test('defaults and origin', () => {
    const c = loadConfig({ PUBLIC_BASE_URL: 'https://api.example.com:8443/' });
    assert.deepEqual(c, {
      publicBaseUrl: 'https://api.example.com:8443',
      publicOrigin: 'https://api.example.com:8443',
      suffixLength: 8,
    });
  });
  test('invalid values', () => {
    assert.throws(() => loadConfig({}));
    assert.throws(() => loadConfig({ PUBLIC_BASE_URL: 'ftp://x' }));
    assert.throws(() => loadConfig({ PUBLIC_BASE_URL: BASE, TICKET_SUFFIX_LENGTH: '0' }));
  });
});

describe('qr', () => {
  for (const text of ['20261001194300-7K3QX9MZ', '20261231235959-ABCDEFGHJKMN', 'x'.repeat(120)]) {
    test(text, () => {
      const png = qrPng(text);
      assert.deepEqual(png.subarray(0, 8), Buffer.from(PNG_MAGIC));
      // Largest whole-pixel module size that fits in 256px, with a 4-module quiet zone on each side.
      const modules = generate(text, { minCorrectionLevel: correction.M, maxCorrectionLevel: correction.M }).size + 8;
      assert.deepEqual(pngSize(png), Array(2).fill(Math.floor(256 / modules) * modules));
    });
  }
  test('content beyond QR capacity fails', () => {
    assert.throws(() => qrPng('x'.repeat(3000)));
  });
});

// ---------------------------------------------------------------- handlers (same cases as Go handler_test.go)

describe('A: POST /v1/tickets/qr-inline', () => {
  test('issues a ticket and returns the QR as base64 JSON', async () => {
    let sent: Uint8Array | undefined;
    const { handle } = newRoute(async (img) => ((sent = img.data), { valid: true, reason: '' }));
    const res = await handle(await formEvent(ISSUE_INLINE, 'image', JPEG));

    assert.equal(res.statusCode, 201, String(res.body));
    assertCommonHeaders(res);
    assert.deepEqual(sent, JPEG, 'analyzer must receive the uploaded bytes unchanged');
    const body = JSON.parse(res.body!);
    assert.match(body.ticketCode, CODE_RE);
    assert.match(body.issuedAt, /\+09:00$/);
    assert.equal(body.qr.mimeType, 'image/png');
    assert.deepEqual(Buffer.from(body.qr.data, 'base64').subarray(0, 8), Buffer.from(PNG_MAGIC));
  });

  const big = new Uint8Array(MAX_IMAGE_BYTES + JPEG.length);
  big.set(JPEG);
  const cases: Array<[string, Analyzer, () => Promise<Event>, number, string]> = [
    [
      'json instead of form',
      alwaysValid,
      async () => rawEvent(ISSUE_INLINE, 'application/json', '{}'),
      415,
      'UNSUPPORTED_MEDIA_TYPE',
    ],
    [
      'urlencoded instead of multipart',
      alwaysValid,
      async () => rawEvent(ISSUE_INLINE, 'application/x-www-form-urlencoded', 'image=x'),
      415,
      'UNSUPPORTED_MEDIA_TYPE',
    ],
    [
      'no boundary',
      alwaysValid,
      async () => rawEvent(ISSUE_INLINE, 'multipart/form-data', 'x'),
      415,
      'UNSUPPORTED_MEDIA_TYPE',
    ],
    [
      'image sent as a text field',
      alwaysValid,
      async () =>
        rawEvent(
          ISSUE_INLINE,
          'multipart/form-data; boundary=xyz',
          '--xyz\r\nContent-Disposition: form-data; name="image"\r\n\r\nhello\r\n--xyz--\r\n',
        ),
      400,
      'BAD_REQUEST',
    ],
    [
      'broken multipart',
      alwaysValid,
      async () => rawEvent(ISSUE_INLINE, 'multipart/form-data; boundary=xyz', 'garbage'),
      400,
      'BAD_REQUEST',
    ],
    [
      'empty boundary',
      alwaysValid,
      () => withContentType(formEvent(ISSUE_INLINE, 'image', JPEG), 'multipart/form-data; boundary=""'),
      415,
      'UNSUPPORTED_MEDIA_TYPE',
    ],
    [
      'boundary without value',
      alwaysValid,
      () => withContentType(formEvent(ISSUE_INLINE, 'image', JPEG), 'multipart/form-data; boundary'),
      415,
      'UNSUPPORTED_MEDIA_TYPE',
    ],
    ['broken after the image part', alwaysValid, () => brokenAfterImage(ISSUE_INLINE), 400, 'BAD_REQUEST'],
    ['missing image field', alwaysValid, () => formEvent(ISSUE_INLINE, 'file', JPEG), 400, 'BAD_REQUEST'],
    ['empty image', alwaysValid, () => formEvent(ISSUE_INLINE, 'image', new Uint8Array()), 400, 'BAD_REQUEST'],
    [
      'not an image',
      alwaysValid,
      () => formEvent(ISSUE_INLINE, 'image', Buffer.from('hello')),
      415,
      'UNSUPPORTED_MEDIA_TYPE',
    ],
    ['too large', alwaysValid, () => formEvent(ISSUE_INLINE, 'image', big), 413, 'PAYLOAD_TOO_LARGE'],
    [
      'rejected',
      stub({ valid: false, reason: 'blurry' }),
      () => formEvent(ISSUE_INLINE, 'image', JPEG),
      422,
      'IMAGE_INVALID',
    ],
    [
      'upstream error',
      stub({}, new AnalyzerError('upstream', 'boom')),
      () => formEvent(ISSUE_INLINE, 'image', JPEG),
      502,
      'ANALYSIS_UPSTREAM_ERROR',
    ],
    [
      'timeout',
      stub({}, new AnalyzerError('timeout', 'slow')),
      () => formEvent(ISSUE_INLINE, 'image', JPEG),
      504,
      'ANALYSIS_TIMEOUT',
    ],
    [
      'unexpected analyzer error',
      stub({}, new Error('bug')),
      () => formEvent(ISSUE_INLINE, 'image', JPEG),
      502,
      'ANALYSIS_UPSTREAM_ERROR',
    ],
  ];
  for (const [name, analyzer, makeEvent, status, code] of cases) {
    test(name, async () => {
      const res = await newRoute(analyzer).handle(await makeEvent());
      assert.equal(res.statusCode, status);
      assert.equal(errorCode(res), code);
    });
  }
});

// Follows the browser: POST form → 303 → view HTML → img src → PNG.
test('B: PRG flow', async () => {
  const { handle } = newRoute();

  let res = await handle(await formEvent(ISSUE, 'image', PNG));
  assert.equal(res.statusCode, 303, String(res.body));
  assertCommonHeaders(res);
  const loc = new URL(header(res, 'Location'));
  const m = /^\/v1\/tickets\/([^/]+)\/view$/.exec(loc.pathname);
  assert.equal(loc.origin, BASE);
  assert.ok(m && CODE_RE.test(m[1]), `unexpected Location ${loc}`);
  const code = m![1];
  const sig = loc.searchParams.get('sig')!;

  res = await handle(signedGet('view', code, sig));
  assert.equal(res.statusCode, 200);
  assert.match(header(res, 'Content-Type'), /^text\/html/);
  assert.match(header(res, 'Content-Security-Policy'), new RegExp(`img-src ${BASE}`));
  assert.ok(res.body!.includes(`src="${BASE}/v1/tickets/${code}/qr?sig=${encodeURIComponent(sig)}"`), String(res.body));
  assert.ok(res.body!.includes(`data-ticket-code="${code}"`));

  res = await handle(signedGet('qr', code, sig));
  assert.equal(res.statusCode, 200);
  assert.equal(header(res, 'Content-Type'), 'image/png');
  assert.equal(res.isBase64Encoded, true);
  assert.deepEqual(Buffer.from(res.body!, 'base64').subarray(0, 8), Buffer.from(PNG_MAGIC));
});

describe('valid spellings of a multipart Content-Type (same as the Go tests, minus known differences)', () => {
  for (const format of [
    'multipart/form-data; boundary="%s"',
    'Multipart/Form-Data; boundary=%s',
    'multipart/form-data; boundary=%s;',
    'multipart/form-data ; charset=utf-8; boundary=%s',
    'multipart/form-data; boundary=%s; boundary=%s',
  ]) {
    test(format, async () => {
      const { handle } = newRoute();
      const res = await handle(await withContentType(formEvent(ISSUE_INLINE, 'image', JPEG), format));
      assert.equal(res.statusCode, 201, String(res.body));
    });
  }
});

// Unusual spellings that browsers never send, where Node (WHATWG rules, like formData()) differs from
// Go (mime.ParseMediaType). Known differences, NODE.md 10.
describe('Content-Type spellings that differ from Go (known differences)', () => {
  const cases: Array<[string, number]> = [
    ['multipart/form-data; BOUNDARY = %s', 415], // Go: 201 (spaces around "=")
    ['multipart/form-data; boundary=%s; boundary=other', 201], // Go: 415 (conflicting values; the first wins)
    ['multipart/form-data; boundary=%s x', 400], // Go: 415 (the boundary becomes "… x" and the body does not match)
  ];
  for (const [format, status] of cases) {
    test(format, async () => {
      const res = await newRoute().handle(await withContentType(formEvent(ISSUE_INLINE, 'image', JPEG), format));
      assert.equal(res.statusCode, status, String(res.body));
    });
  }
});

describe('B-1 errors are HTML views', () => {
  const cases: Array<[string, Analyzer, () => Promise<Event>, number, string]> = [
    [
      'json instead of form',
      alwaysValid,
      async () => rawEvent(ISSUE, 'application/json', '{}'),
      415,
      'UNSUPPORTED_MEDIA_TYPE',
    ],
    ['missing image field', alwaysValid, () => formEvent(ISSUE, 'file', JPEG), 400, 'BAD_REQUEST'],
    ['not an image', alwaysValid, () => formEvent(ISSUE, 'image', Buffer.from('hello')), 415, 'UNSUPPORTED_MEDIA_TYPE'],
    ['rejected', stub({ valid: false }), () => formEvent(ISSUE, 'image', JPEG), 422, 'IMAGE_INVALID'],
  ];
  for (const [name, analyzer, makeEvent, status, code] of cases) {
    test(name, async () => {
      const res = await newRoute(analyzer).handle(await makeEvent());
      assert.equal(res.statusCode, status);
      assert.match(header(res, 'Content-Type'), /^text\/html/);
      assert.ok(res.body!.includes(`data-error-code="${code}"`), String(res.body));
      assert.equal(header(res, 'Location'), '');
      assertCommonHeaders(res);
      assert.match(header(res, 'Content-Security-Policy'), /img-src https:\/\/api\.example\.com/);
    });
  }
});

describe('signature required', () => {
  const { deps, handle } = newRoute();
  const code = '20261001194300-7K3QX9MZ';
  const cases: Array<[string, string, string]> = [
    ['missing sig', code, ''],
    ['sig for other code', code, deps.signer.sign('20261001000000-00000000')],
    ['garbage sig', code, 'x'.repeat(22)],
  ];
  for (const [name, c, sig] of cases) {
    test(name, async () => {
      const view = await handle(signedGet('view', c, sig));
      assert.equal(view.statusCode, 403);
      assert.ok(view.body!.includes('data-error-code="FORBIDDEN"'));
      const qr = await handle(signedGet('qr', c, sig));
      assert.equal(qr.statusCode, 403);
      assert.equal(errorCode(qr), 'FORBIDDEN');
    });
  }

  // An empty path segment matches no route, as on API Gateway (Go returns 403 only when invoked directly).
  test('missing code is 404', async () => {
    for (const resource of ['view', 'qr']) {
      const res = await handle(event({ path: `/v1/tickets//${resource}`, query: `sig=${deps.signer.sign(code)}` }));
      assert.equal(res.statusCode, 404);
      assert.equal(errorCode(res), 'NOT_FOUND');
    }
  });
});

test('view escapes a signed but hostile ticket code', async () => {
  // The code is not format-checked, so a signed hostile value must still be escaped.
  const { deps, handle } = newRoute();
  const code = '"><script>alert(1)</script>';
  const res = await handle(signedGet('view', code, deps.signer.sign(code)));
  assert.equal(res.statusCode, 200);
  assert.ok(!res.body!.includes('<script>'), String(res.body));
});

test('unknown route is 404 JSON', async () => {
  const res = await newRoute().handle(event({ path: '/v1/unknown' }));
  assert.equal(res.statusCode, 404);
  assert.equal(errorCode(res), 'NOT_FOUND');
  assertCommonHeaders(res);
});

test('example.com QR', async () => {
  const res = await (handle(createExampleApp()) as LambdaHandler)(event({ path: '/v1/example/qr' }));
  assert.equal(res.statusCode, 200);
  assert.equal(header(res, 'Content-Type'), 'image/png');
  assert.equal(header(res, 'Cache-Control'), 'no-store');
  assert.equal(res.isBase64Encoded, true);
  assert.deepEqual(Buffer.from(res.body!, 'base64').subarray(0, 8), Buffer.from(PNG_MAGIC));
});

// ---------------------------------------------------------------- HTTP analyzer client (analyzer-stub/DESIGN.md 3)

describe('http analyzer client', () => {
  // A local server whose behavior is scripted per test; it records every request it receives.
  type Reply = (req: IncomingMessage, res: ServerResponse) => void;
  let replies: Reply[] = [];
  const received: Array<{ headers: IncomingMessage['headers']; body: Buffer }> = [];
  const server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    received.push({ headers: req.headers, body: Buffer.concat(chunks) });
    (replies.shift() ?? ((_, r) => r.writeHead(599).end()))(req, res);
  });
  const listening = new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  after(() => server.close());

  const json =
    (status: number, body: unknown): Reply =>
    (_, res) =>
      res.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(body));
  const hang: Reply = () => {}; // never answers

  async function client(...script: Reply[]) {
    await listening;
    replies = script;
    received.length = 0;
    const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/analyze`;
    return httpAnalyzer({ url, apiKey: 'k', timeoutMs: 200 });
  }
  const analyze = (a: Awaited<ReturnType<typeof client>>) => a({ data: JPEG, mimeType: 'image/jpeg' });

  test('posts the image bytes unchanged as octet-stream with the API key', async () => {
    const a = await client(json(200, { valid: true, reason: 'ok' }));
    assert.deepEqual(await analyze(a), { valid: true, reason: 'ok' });
    assert.equal(received.length, 1);
    assert.equal(received[0].headers['content-type'], 'application/octet-stream');
    assert.equal(received[0].headers['x-api-key'], 'k');
    assert.deepEqual(new Uint8Array(received[0].body), JPEG);
  });

  test('valid: false is a result, not an error', async () => {
    assert.deepEqual(await analyze(await client(json(200, { valid: false }))), { valid: false, reason: '' });
  });

  // [name, server replies in order, expected request count, expected outcome]
  const retries: Array<[string, Reply[], number, 'valid' | 'upstream' | 'timeout']> = [
    ['5xx is retried once and succeeds', [json(500, {}), json(200, { valid: true })], 2, 'valid'],
    ['no answer is retried once and succeeds', [hang, json(200, { valid: true })], 2, 'valid'],
    ['5xx twice is an upstream error', [json(500, {}), json(502, {})], 2, 'upstream'],
    ['no answer twice is a timeout', [hang, hang], 2, 'timeout'],
    ['4xx is not retried', [json(401, {})], 1, 'upstream'],
    ['malformed body is not retried', [json(200, { valid: 'yes' })], 1, 'upstream'],
  ];
  for (const [name, script, calls, outcome] of retries) {
    test(name, async () => {
      const a = await client(...script);
      if (outcome === 'valid') {
        assert.equal((await analyze(a)).valid, true);
      } else {
        await assert.rejects(analyze(a), (err: unknown) => err instanceof AnalyzerError && err.kind === outcome);
      }
      assert.equal(received.length, calls);
    });
  }

  test('the API maps analyzer failures to 502 / 504 and invalid to 422', async () => {
    const cases: Array<[Reply[], number, string]> = [
      [[json(200, { valid: false })], 422, 'IMAGE_INVALID'],
      [[json(500, {}), json(500, {})], 502, 'ANALYSIS_UPSTREAM_ERROR'],
      [[hang, hang], 504, 'ANALYSIS_TIMEOUT'],
    ];
    for (const [script, status, code] of cases) {
      const { handle } = newRoute(await client(...script));
      const res = await handle(await formEvent(ISSUE_INLINE, 'image', JPEG));
      assert.equal(res.statusCode, status);
      assert.equal(errorCode(res), code);
    }
  });

  test('newAnalyzer validates http settings', async () => {
    await assert.rejects(newAnalyzer({ ANALYZER_MODE: 'http' }), /ANALYZER_URL/);
    await assert.rejects(
      newAnalyzer({ ANALYZER_MODE: 'http', ANALYZER_URL: 'http://x/v1/analyze' }),
      /ANALYZER_API_KEY_PARAMETER_NAME/,
    );
    await assert.rejects(newAnalyzer({ ANALYZER_MODE: 'nope' }), /unsupported/);
    assert.equal(await newAnalyzer({ ANALYZER_MODE: 'mock' }), alwaysValid);
    const a = await newAnalyzer({
      ANALYZER_MODE: 'http',
      ANALYZER_URL: 'http://x/v1/analyze',
      APP_ENV: 'local',
      ANALYZER_API_KEY: 'k',
    });
    assert.equal(typeof a, 'function');
  });
});

// ---------------------------------------------------------------- accepted upload formats

describe('upload formats (iPhone / Android photos as-is)', () => {
  const accepted: Array<[string, string]> = [
    ['photo.jpg', 'image/jpeg'],
    ['photo.png', 'image/png'],
    ['photo.heic', 'image/heic'],
    ['photo-mif1.heif', 'image/heif'],
    ['photo.avif', 'image/avif'],
    ['photo.webp', 'image/webp'],
  ];
  for (const [file, mimeType] of accepted) {
    test(`${file} is accepted as ${mimeType} and forwarded unchanged`, async () => {
      let sent: { data: Uint8Array; mimeType: string } | undefined;
      const { handle } = newRoute(async (img) => ((sent = img), { valid: true, reason: '' }));
      const res = await handle(await formEvent(ISSUE_INLINE, 'image', image(file)));
      assert.equal(res.statusCode, 201, String(res.body));
      assert.equal(sent?.mimeType, mimeType);
      assert.deepEqual(sent?.data, image(file));
    });
  }

  const rejected: Array<[string, Uint8Array]> = [
    ['plain text', image('not-image.txt')],
    [
      'JPEG magic bytes only (not a real image)',
      Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]),
    ],
    ['PNG signature only', Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0])],
    ['WebP header without data', Buffer.from('RIFF\x04\x00\x00\x00WEBP', 'latin1')],
    ['HEIC ftyp box only', Buffer.from('\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic', 'latin1')],
    ['AVIF ftyp box only', Buffer.from('\x00\x00\x00\x18ftypavif\x00\x00\x00\x00mif1avif', 'latin1')],
  ];
  for (const [name, data] of rejected) {
    test(`${name} is 415`, async () => {
      const res = await newRoute().handle(await formEvent(ISSUE_INLINE, 'image', data));
      assert.equal(res.statusCode, 415);
      assert.equal(errorCode(res), 'UNSUPPORTED_MEDIA_TYPE');
    });
  }
});

// ---------------------------------------------------------------- B-1 for the SPA (Accept: application/json)

describe('B-1 with Accept: application/json', () => {
  const asJson = (e: Event) => ((e.headers.accept = 'application/json'), e);

  test('returns the signed QR URL as JSON instead of a redirect', async () => {
    const { deps, handle } = newRoute();
    const res = await handle(asJson(await formEvent(ISSUE, 'image', JPEG)));
    assert.equal(res.statusCode, 201, String(res.body));
    assert.match(header(res, 'Content-Type'), /^application\/json/);
    assert.equal(header(res, 'Location'), '');
    assert.equal(header(res, 'Vary'), 'Accept');
    const body = JSON.parse(res.body!);
    assert.match(body.ticketCode, CODE_RE);
    assert.match(body.issuedAt, /\+09:00$/);
    assert.ok(deps.signer.verify(body.ticketCode, body.sig));
    assert.equal(body.qrUrl, `${BASE}/v1/tickets/${body.ticketCode}/qr?sig=${encodeURIComponent(body.sig)}`);

    // The returned URL serves the QR (B-2), so the SPA can render <img src=qrUrl>.
    const qr = await handle(signedGet('qr', body.ticketCode, body.sig));
    assert.equal(qr.statusCode, 200);
    assert.equal(header(qr, 'Content-Type'), 'image/png');
  });

  test('errors are JSON', async () => {
    const res = await newRoute().handle(asJson(await formEvent(ISSUE, 'image', Buffer.from('hello'))));
    assert.equal(res.statusCode, 415);
    assert.equal(errorCode(res), 'UNSUPPORTED_MEDIA_TYPE');
  });

  test('a browser form (Accept: text/html, ...) still gets the redirect', async () => {
    const e = await formEvent(ISSUE, 'image', JPEG);
    e.headers.accept = 'text/html,application/xhtml+xml,*/*;q=0.8';
    assert.equal((await newRoute().handle(e)).statusCode, 303);
  });
});

describe('client log (browser and OS of image uploads)', () => {
  const IOS13 =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 13_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.4 Mobile/15E148 Safari/604.1';
  const CLIENT = {
    'user-agent': IOS13,
    'sec-ch-ua': '"Chromium";v="138", "Google Chrome";v="138"',
    'sec-ch-ua-mobile': '?1',
    'sec-ch-ua-platform': '"Android"',
  };

  // Runs the events and returns the "request completed" entries.
  async function completedLogs(...events: Event[]) {
    const entries: Array<Record<string, unknown>> = [];
    const { handle } = newRoute(alwaysValid, (_level, msg, fields) => {
      if (msg === 'request completed') entries.push(fields ?? {});
    });
    for (const e of events) await handle(e);
    return entries;
  }

  const withHeaders = (e: Event, headers: Record<string, string>) => {
    const ev = e as unknown as { headers: Record<string, string> };
    ev.headers = { ...ev.headers, ...headers };
    return e;
  };

  test('upload endpoints log the User-Agent and Client Hints (same keys as Go); other endpoints do not', async () => {
    const logs = await completedLogs(
      withHeaders(await formEvent(ISSUE_INLINE, 'image', JPEG), CLIENT),
      withHeaders(await formEvent('/v1/tickets', 'image', Buffer.from('not an image')), CLIENT), // errors too
      withHeaders(signedGet('qr', 'X', 'Y'), { 'user-agent': IOS13 }),
    );
    assert.equal(logs.length, 3);
    const want = {
      userAgent: IOS13,
      secChUa: '"Chromium";v="138", "Google Chrome";v="138"',
      secChUaMobile: '?1',
      secChUaPlatform: '"Android"',
    };
    assert.deepEqual(logs[0]!.client, want);
    assert.deepEqual(logs[1]!.client, want);
    assert.equal(logs[1]!.status, 415);
    assert.equal(logs[2]!.endpoint, 'get-qr');
    assert.equal('client' in logs[2]!, false);
  });

  test('values are cut to 512 characters and an empty client is omitted', async () => {
    const logs = await completedLogs(
      withHeaders(await formEvent(ISSUE_INLINE, 'image', JPEG), { 'user-agent': 'a'.repeat(2000) }),
      await formEvent(ISSUE_INLINE, 'image', JPEG),
    );
    assert.equal((logs[0]!.client as { userAgent: string }).userAgent.length, 512);
    assert.equal('client' in logs[1]!, false);
  });
});
