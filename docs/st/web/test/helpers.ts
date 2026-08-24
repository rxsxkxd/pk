// Test helpers: mount a page with the config, a fresh Pinia and an in-memory router.
import { mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import { vi } from 'vitest';
import { createApp } from 'vue';
import { createMemoryHistory, type RouteRecordRaw } from 'vue-router';
import App from '../src/App.vue';
import { configKey, MAX_IMAGE_BYTES, type AppConfig } from '../src/config.ts';
import { GRANT_MODES, type ModeEntry } from '../src/modes/types.ts';
import { createAppRouter } from '../src/router.ts';

export const API = 'https://api.example.com';
export const CODE = '202610051350543f2b9c1e8a4d4f6b8e0c7a1d2b3c4d5eTQR';
export const SIG = 'abcdefghijklmnopqrstuv';

// The grant modes whose folder (src/modes/<mode>/) is present, in GRANT_MODES order. Only the built mode's folder is
// needed (web/DESIGN.md 4.1), so the tests shared by every mode take the modes from here instead of importing each
// folder: removing a mode's folder (and its test/modes/<mode>.test.ts) keeps the type check and the tests working.
export const MODE_FOLDERS = import.meta.glob<ModeEntry>('../src/modes/*/index.ts', { eager: true });
export const MODES: ModeEntry[] = Object.values(MODE_FOLDERS).sort(
  (a, b) => GRANT_MODES.indexOf(a.mode) - GRANT_MODES.indexOf(b.mode),
);

export function config(): AppConfig {
  return { apiBaseUrl: API, maxImageBytes: MAX_IMAGE_BYTES };
}

// A store needs the app-level config (inject) and an active Pinia, as in main.ts.
export function setupStore(cfg = config()) {
  const app = createApp({});
  const pinia = createPinia();
  app.provide(configKey, cfg).use(pinia);
  setActivePinia(pinia);
  return app;
}

// Mounts the app with one grant mode's routes (src/modes/<mode>/index.ts), as main.ts does with '@mode'.
export async function mountAt(routes: RouteRecordRaw[], path: string, cfg = config()) {
  const router = createAppRouter(routes, createMemoryHistory());
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

// 画像の選択欄でファイルを選んだことにする。
export async function choosePhoto(wrapper: Awaited<ReturnType<typeof mountAt>>['wrapper'], file = photo()) {
  const input = wrapper.get('[data-testid="image-input"]');
  Object.defineProperty(input.element, 'files', { value: [file], configurable: true });
  await input.trigger('change');
}
