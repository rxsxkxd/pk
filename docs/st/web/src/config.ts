// Runtime configuration, read from /config.json at startup so one build can be deployed to every
// environment by swapping that file (DESIGN.md 4.1).

import type { InjectionKey } from 'vue';
import { z } from 'zod';

// Issue modes: page = 画面遷移方式 (main), inline = その場表示方式, form = フォーム送信方式 (options).
export const ModeSchema = z.enum(['page', 'inline', 'form']);
export type Mode = z.infer<typeof ModeSchema>;

export const ConfigSchema = z.object({
  // "" = same origin (the Vite proxy in development); otherwise the API's http(s) origin, without a trailing slash.
  apiBaseUrl: z.union([z.literal(''), z.url({ protocol: /^https?$/ })]).transform((u) => u.replace(/\/+$/, '')),
  modes: z.array(ModeSchema).min(1).default(['page']),
});
export type AppConfig = z.infer<typeof ConfigSchema>;

export const configKey: InjectionKey<AppConfig> = Symbol('config');

// config.json を取得して検証する（形が違えば例外。画面は起動しない）。
export async function loadConfig(url = `${import.meta.env.BASE_URL}config.json`): Promise<AppConfig> {
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) throw new Error(`config.json: HTTP ${res.status}`);
  return ConfigSchema.parse(await res.json());
}
