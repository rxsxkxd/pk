// Lambda entry for the ticket endpoints (ticketqr.zip). Initialization runs once, during the
// Lambda init phase, via top-level await.
import { loadDeps, route } from './lib.ts';

export const handler = route(await loadDeps());
