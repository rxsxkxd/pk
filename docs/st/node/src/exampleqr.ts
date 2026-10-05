// Lambda entry for GET /v1/example/qr (exampleqr.zip, infra/cloudformation/example.yaml). No configuration.
import { handle } from '@hono/aws-lambda';
import { createExampleApp } from './example.ts';

export const handler = handle(createExampleApp());
