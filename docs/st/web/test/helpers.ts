// Test helpers: mount a page with the config, a fresh Pinia and an in-memory router.
import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { vi } from 'vitest';
import { createApp } from 'vue';
import { createMemoryHistory } from 'vue-router';
import App from '../src/App.vue';
import { configKey, type AppConfig } from '../src/config.ts';
import { createAppRouter } from '../src/router.ts';

export const API = 'https://api.example.com';
export const CODE = '202610051350543f2b9c1e8a4d4f6b8e0c7a1d2b3c4d5eTQR';
export const SIG = 'abcdefghijklmnopqrstuv';

export function config(modes: AppConfig['modes'] = ['page']): AppConfig {
  return { apiBaseUrl: API, modes };
}

// A store needs the app-level config (inject) and an active Pinia, as in main.ts.
export function setupStore(cfg = config()) {
  const app = createApp({});
  const pinia = createPinia();
  app.provide(configKey, cfg).use(pinia);
  setActivePinia(pinia);
  return app;
}

export async function mountAt(path: string, cfg = config()) {
  const router = createAppRouter(createMemoryHistory());
  await router.push(path);
  await router.isReady();
  const wrapper = mount(App, {
    global: { plugins: [createPinia(), router], provide: { [configKey as symbol]: cfg } },
  });
  return { wrapper, router };
}

export function photo(name = 'IMG_0001.HEIC', type = 'image/heic', size = 1024): File {
  return new File([new Uint8Array(size)], name, { type });
}

// fetch のスタブ。応答を順に返し、呼び出しを記録する。
export function stubFetch(...responses: Array<Response | Error>) {
  const fn = vi.fn(async (_url: string, _init?: RequestInit) => {
    const r = responses.shift();
    if (!r) throw new Error('no more stubbed responses');
    if (r instanceof Error) throw r;
    return r;
  });
  vi.stubGlobal('fetch', fn);
  return fn;
}

export const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
