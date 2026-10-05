/// <reference types="vitest/config" />
import tailwindcss from '@tailwindcss/vite';
import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [vue(), tailwindcss()],
  // Local development: forward API calls to the local API (Go `make run` / Node `npm run dev`), so the SPA
  // and the API share one origin and no CORS is needed (DESIGN.md 8).
  server: { proxy: { '/v1': 'http://localhost:8080' } },
  test: { environment: 'happy-dom' },
});
