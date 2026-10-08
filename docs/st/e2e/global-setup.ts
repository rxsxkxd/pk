// Before the tests: wait for the API, then deploy the prebuilt SPA to the buckets "web" and "evil" as the
// production deploy does (E2E.md 3.2).

import { readdir, readFile } from 'node:fs/promises';
import { extname, join, relative } from 'node:path';
import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { API_URL, S3_KEY, S3_URL, WEB_DIST } from './env.ts';

const CONTENT_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

// The SPA's runtime config in E2E: every mode on, so the optional ones can be tested too.
const CONFIG = { apiBaseUrl: API_URL, modes: ['page', 'inline', 'form'] };

export default async function globalSetup(): Promise<void> {
  await waitForApi();
  const s3 = new S3Client({ endpoint: S3_URL, region: 'garage', forcePathStyle: true, credentials: S3_KEY });
  const files = await listFiles(WEB_DIST);
  for (const bucket of ['web', 'evil']) {
    for (const file of files) {
      const key = relative(WEB_DIST, file);
      await put(s3, bucket, key, await readFile(file));
    }
    await put(s3, bucket, 'config.json', JSON.stringify(CONFIG));
  }
  console.log(`deployed ${files.length} files + config.json to web, evil`);
}

async function put(s3: S3Client, bucket: string, key: string, body: Uint8Array | string): Promise<void> {
  const ContentType = CONTENT_TYPES[extname(key)] ?? 'application/octet-stream';
  const CacheControl =
    key === 'index.html' || key === 'config.json' ? 'no-cache' : 'public, max-age=31536000, immutable';
  await s3.send(new PutObjectCommand({ Bucket: bucket, Key: key, Body: body, ContentType, CacheControl }));
}

async function listFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true, recursive: true });
  const files = entries.filter((e) => e.isFile()).map((e) => join(e.parentPath, e.name));
  if (!files.some((f) => f.endsWith('index.html'))) throw new Error(`${dir} has no index.html: build web/ first`);
  return files;
}

// The Lambda image has no healthcheck command: poll the gateway until the function answers (a QR request
// with a wrong signature is a 403 from the function itself).
async function waitForApi(): Promise<void> {
  const url = `${API_URL}/v1/tickets/2026010100000000000000000000000000000000000000WAIT/qr?sig=AAAAAAAAAAAAAAAAAAAAAA`;
  const deadline = Date.now() + 60_000;
  for (;;) {
    const status = await fetch(url).then(
      (r) => r.status,
      () => 0,
    );
    if (status === 403) return;
    if (Date.now() > deadline) throw new Error(`API not ready (last status ${status})`);
    await new Promise((r) => setTimeout(r, 500));
  }
}
