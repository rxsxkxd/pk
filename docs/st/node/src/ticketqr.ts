// Lambda entry for the ticket endpoints (ticketqr.zip). Initialization runs once, during the
// Lambda init phase, via top-level await.
import { handle } from '@hono/aws-lambda';
import { createApp, loadDeps } from './app.ts';

export const handler = handle(createApp(await loadDeps()));
