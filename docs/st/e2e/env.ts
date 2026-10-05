// URLs and test credentials of the compose network (E2E.md 2.1). Overridable for runs outside compose.
export const WEB_URL = process.env.WEB_URL ?? 'http://web:3902';
export const API_URL = process.env.API_URL ?? 'http://api:3000';
export const S3_URL = process.env.S3_URL ?? 'http://storage:3900';
export const WEB_DIST = process.env.WEB_DIST ?? '/web-dist';
export const FIXTURES = process.env.FIXTURES ?? '/fixtures';

// Test-only key created by docker/storage/init.sh. Not a secret.
export const S3_KEY = {
  accessKeyId: 'GK00000000000000000000e2e0',
  secretAccessKey: 'e2e0000000000000000000000000000000000000000000000000000000000000',
};
