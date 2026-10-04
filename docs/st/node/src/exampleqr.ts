// Lambda entry for GET /v1/example/qr (exampleqr.zip). Needs no configuration or secrets.
import { handle } from '@hono/aws-lambda';
import { createExampleApp } from './app.ts';

export const handler = handle(createExampleApp());
