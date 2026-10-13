// Runtime configuration, read from /config.json at startup so one build can be deployed to every
// environment of its grant mode by swapping that file (DESIGN.md 4.1). The grant mode itself is chosen at
// build time (GRANT_MODE, src/modes/types.ts), not here.

import type { InjectionKey } from 'vue';
import * as v from 'valibot';

// Upload ceiling of the API (Lambda's 6MB request, base64 by API Gateway). An environment can only lower it.
export const MAX_IMAGE_BYTES = 4 << 20;

// v.object drops unknown keys (e.g. a leftover "modes").
export const ConfigSchema = v.object({
  // "" = same origin (the Vite proxy in development); otherwise the API's http(s) origin, without a trailing slash.
  apiBaseUrl: v.pipe(
    v.union([
      v.literal(''),
      v.pipe(
        v.string(),
        v.url(),
        v.check((u) => /^https?:\/\//.test(u), 'must be an http(s) URL'),
      ),
    ]),
    v.transform((u) => u.replace(/\/+$/, '')),
  ),
  // Upload limit of this environment: the same value as the API's MAX_IMAGE_BYTES (it may differ by the
  // path to the API, ../DESIGN.md 5). Checked before sending; the API makes the final decision.
  maxImageBytes: v.optional(
    v.pipe(v.number(), v.integer(), v.minValue(1), v.maxValue(MAX_IMAGE_BYTES)),
    MAX_IMAGE_BYTES,
  ),
});
export type AppConfig = v.InferOutput<typeof ConfigSchema>;

export const configKey: InjectionKey<AppConfig> = Symbol('config');

// config.json を取得して検証する（形が違えば例外。画面は起動しない）。
export async function loadConfig(url = `${import.meta.env.BASE_URL}config.json`): Promise<AppConfig> {
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) throw new Error(`config.json: HTTP ${res.status}`);
  return v.parse(ConfigSchema, await res.json());
}
