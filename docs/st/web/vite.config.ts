/// <reference types="vitest/config" />
import { fileURLToPath } from 'node:url';
import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';
import { GRANT_MODES, type GrantMode } from './src/modes/types.ts';

// The grant mode is chosen at build time (DESIGN.md 4.1): GRANT_MODE=page|inline|form, default page (the main
// mode). '@mode' points at that mode's directory only, so the other modes are not in the build.
const grantMode = (process.env.GRANT_MODE || 'page') as GrantMode;
if (!GRANT_MODES.includes(grantMode)) {
  throw new Error(`GRANT_MODE must be one of ${GRANT_MODES.join(', ')}, got "${grantMode}"`);
}

export default defineConfig({
  plugins: [vue()], // Tailwind CSS 3.4 runs through PostCSS (postcss.config.js)
  resolve: {
    alias: { '@mode': fileURLToPath(new URL(`./src/modes/${grantMode}/index.ts`, import.meta.url)) },
  },
  // CSS for the supported browsers (DESIGN.md 2.1): the minifier must not turn it into newer syntax. The JS
  // target (build.target) is a separate change (DESIGN.md 2.4).
  build: { cssTarget: ['safari13', 'chrome80'] },
  // Local development: forward API calls to the local API (Go `make run` / Node `npm run dev`), so the SPA
  // and the API share one origin and no CORS is needed (DESIGN.md 8).
  server: { proxy: { '/v1': 'http://localhost:8080' } },
  test: { environment: 'happy-dom' },
});
