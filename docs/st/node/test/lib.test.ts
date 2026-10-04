import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { handle } from '@hono/aws-lambda';
import type { APIGatewayProxyEventV2 as Event, APIGatewayProxyStructuredResultV2 as Result } from 'aws-lambda';
import { correction, generate } from 'lean-qr';
import {
  alwaysValid,
  AnalyzerError,
  createApp,
  createExampleApp,
  generateTicket,
  loadConfig,
  loadViews,
  MAX_IMAGE_BYTES,
  newSigner,
  qrPng,
  ROUTE_KEYS,
  type Analyzer,
  type Deps,
} from '../src/lib.ts';

const root = new URL('../../', import.meta.url);
const vectors = (name: string) => JSON.parse(readFileSync(new URL(`testdata/${name}`, root), 'utf8'));

const JPEG = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
const PNG = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0]);
const PNG_MAGIC = PNG.subarray(0, 8);
const CODE_RE = /^\d{14}-[0-9A-HJKMNP-TV-Z]{8}$/;
const BASE = 'https://api.example.com';

const ISSUE_INLINE = '/v1/tickets/qr-inline';
const ISSUE = '/v1/tickets';

test('route table matches the API Gateway route keys (same as Go handler.RouteKeys)', () => {
  assert.deepEqual(ROUTE_KEYS, [
    'POST /v1/tickets/qr-inline',
    'POST /v1/tickets',
    'GET /v1/tickets/{ticketCode}/view',
    'GET /v1/tickets/{ticketCode}/qr',
  ]);
});

// ---------------------------------------------------------------- helpers
// Requests go through @hono/aws-lambda, so the tests also cover the Lambda event conversion.

const views = loadViews(fileURLToPath(new URL('templates/', root)));

type LambdaHandler = (event: Event) => Promise<Result>;

function newRoute(analyzer: Analyzer = alwaysValid) {
  const deps: Deps = {
    config: { publicBaseUrl: BASE, publicOrigin: BASE, suffixLength: 8, analyzerMode: 'mock' },
    analyzer,
    signer: newSigner('test-salt'),
    views,
    newTicket: () => generateTicket(8),
    log: () => {},
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
    const c = loadConfig({ PUBLIC_BASE_URL: 'https://api.example.com:8443/', ANALYZER_MODE: 'mock' });
    assert.deepEqual(c, {
      publicBaseUrl: 'https://api.example.com:8443',
      publicOrigin: 'https://api.example.com:8443',
      suffixLength: 8,
      analyzerMode: 'mock',
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
      'no boundary',
      alwaysValid,
      async () => rawEvent(ISSUE_INLINE, 'multipart/form-data', 'x'),
      415,
      'UNSUPPORTED_MEDIA_TYPE',
    ],
    [
      'broken multipart',
      alwaysValid,
      async () => rawEvent(ISSUE_INLINE, 'multipart/form-data; boundary=xyz', 'garbage'),
      400,
      'BAD_REQUEST',
    ],
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
});

test('views reject template syntax other than {{.Field}}', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tpl-'));
  writeFileSync(join(dir, 'ticket.html'), '{{if .TicketCode}}{{.QRURL}}{{end}}');
  writeFileSync(join(dir, 'error.html'), '{{.Code}}');
  assert.throws(() => loadViews(dir), /unsupported template action/);
});

test('example.com QR', async () => {
  const res = await (handle(createExampleApp()) as LambdaHandler)(event({ path: '/v1/example/qr' }));
  assert.equal(res.statusCode, 200);
  assert.equal(header(res, 'Content-Type'), 'image/png');
  assert.equal(header(res, 'Cache-Control'), 'no-store');
  assert.equal(res.isBase64Encoded, true);
  assert.deepEqual(Buffer.from(res.body!, 'base64').subarray(0, 8), Buffer.from(PNG_MAGIC));
});
