// What every grant mode (src/modes/<mode>/index.ts) provides. One mode is chosen at build time: the alias
// '@mode' points at src/modes/$GRANT_MODE (vite.config.ts), so the other modes are not in the build.

import type { RouteRecordRaw } from 'vue-router';

export const GRANT_MODES = ['page', 'inline', 'form'] as const;
export type GrantMode = (typeof GRANT_MODES)[number];

export type ModeEntry = {
  mode: GrantMode;
  // The SPA's screens for this mode; '/' is the grant screen.
  routes: RouteRecordRaw[];
};
