// Lambda entry for GET /v1/example/qr (exampleqr.zip). Needs no configuration or secrets.
import { handle } from '@hono/aws-lambda';
import { createExampleApp } from './lib.ts';

export const handler = handle(createExampleApp());
