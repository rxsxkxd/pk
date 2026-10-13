// Runtime configuration, read from /config.json at startup so one build can be deployed to every
// environment of its grant mode by swapping that file (DESIGN.md 4.1). The grant mode itself is chosen at
// build time (GRANT_MODE, src/modes/types.ts), not here.

import type { InjectionKey } from 'vue';
import * as v from 'valibot';

// Upload ceiling of the API (Lambda's 6MB request, base64 by API Gateway). An environment can only lower it.
export const MAX_IMAGE_BYTES = 4 << 20;

// 同じオリジン（統合の構成、開発時のプロキシ）。API を相対パス（/v1/...）で呼ぶ。
const SameOrigin = v.literal('');

// http / https の絶対 URL（v.url() は ftp: なども通すので、スキームを絞る）。
const HttpUrl = v.pipe(
  v.string(),
  v.url(),
  v.check((u) => /^https?:\/\//.test(u), 'must be an http(s) URL'),
);

// 末尾の "/" を取る（"https://api.example.com/" → "https://api.example.com"）。パスをつなげるときに "//" にしないため。
const withoutTrailingSlash = (u: string) => u.replace(/\/+$/, '');

// API のオリジン: 同じオリジンか、http(s) の URL。
const ApiBaseUrl = v.pipe(v.union([SameOrigin, HttpUrl]), v.transform(withoutTrailingSlash));

// この環境の画像の上限（バイト）: 1 以上 MAX_IMAGE_BYTES 以下の整数。省略したら MAX_IMAGE_BYTES。
// API の MAX_IMAGE_BYTES と同じ値にする（API までの経路で上限が下がることがある。../DESIGN.md 5）。
// 送る前の確認に使い、最終的な判定は API が行う。
const ImageByteLimit = v.optional(
  v.pipe(v.number(), v.integer(), v.minValue(1), v.maxValue(MAX_IMAGE_BYTES)),
  MAX_IMAGE_BYTES,
);

// config.json の形。知らないキー（以前の "modes" など）は取り除く（v.object の動き）。
export const ConfigSchema = v.object({
  apiBaseUrl: ApiBaseUrl,
  maxImageBytes: ImageByteLimit,
});
export type AppConfig = v.InferOutput<typeof ConfigSchema>;

export const configKey: InjectionKey<AppConfig> = Symbol('config');

// config.json を取得して検証する（形が違えば例外。画面は起動しない）。
export async function loadConfig(url = `${import.meta.env.BASE_URL}config.json`): Promise<AppConfig> {
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) throw new Error(`config.json: HTTP ${res.status}`);
  return v.parse(ConfigSchema, await res.json());
}
