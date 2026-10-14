/// <reference types="vitest/config" />
import { existsSync } from 'node:fs';
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
// Only the built mode's folder is needed: the other modes' folders may be removed.
const modeEntry = fileURLToPath(new URL(`./src/modes/${grantMode}/index.ts`, import.meta.url));
if (!existsSync(modeEntry)) {
  throw new Error(`GRANT_MODE=${grantMode}: src/modes/${grantMode}/ is not here (removed?)`);
}

export default defineConfig({
  plugins: [vue()], // Tailwind CSS 3.4 runs through PostCSS (postcss.config.js)
  resolve: {
    alias: { '@mode': modeEntry },
  },
  // Output for the supported browsers (DESIGN.md 2.1, 2.4): newer syntax (?. ?? ??= class fields) is converted
  // and the CSS minifier keeps old syntax. Android's Chrome floor is not decided yet: 80 is provisional (as in
  // package.json "browserslist"). Built-in functions are not converted (core-js in src/main.ts).
  build: { target: ['safari13', 'chrome80'], cssTarget: ['safari13', 'chrome80'] },
  // Local development: forward API calls to the local API (Go `make run` / Node `npm run dev`), so the SPA
  // and the API share one origin and no CORS is needed (DESIGN.md 8).
  server: { proxy: { '/v1': 'http://localhost:8080' } },
  test: { environment: 'happy-dom' },
});
