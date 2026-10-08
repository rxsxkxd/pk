// Grant state of the SPA (DESIGN.md 5): the chosen photo, sending / failed, the inline result and the
// message to show. The page-mode result is not stored: the ticket screen is drawn from its URL only.

import { defineStore } from 'pinia';
import { computed, inject, ref } from 'vue';
import {
  ApiError,
  grantForPage as postForPage,
  grantInline as postInline,
  type InlineTicket,
  type TicketRoute,
} from '../api/tickets.ts';
import { configKey } from '../config.ts';

// Same limit and formats as the API; the API makes the final decision from the file's content.
export const MAX_IMAGE_BYTES = 4 << 20;
export const ACCEPT = 'image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp';
const EXTENSIONS = /\.(jpe?g|png|heic|heif|avif|webp)$/i;

// 送信前に分かる問題を返す（なければ undefined）。形式は MIME タイプか拡張子で目安として確かめる。
export function checkFile(file: File | null): string | undefined {
  if (!file) return '証明書の画像を選んでください';
  if (file.size > MAX_IMAGE_BYTES) return '画像のサイズが大きすぎます（4MB まで）';
  if (!ACCEPT.split(',').includes(file.type) && !EXTENSIONS.test(file.name)) {
    return 'この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）';
  }
  return undefined;
}

// API のエラーを画面に出す文言にする（DESIGN.md 4.4）。
export function messageFor(err: unknown): string {
  switch (err instanceof ApiError ? err.code : '') {
    case 'PAYLOAD_TOO_LARGE':
      return '画像のサイズが大きすぎます（4MB まで）';
    case 'UNSUPPORTED_MEDIA_TYPE':
      return 'この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）';
    case 'IMAGE_REJECTED': // 解析サーバーの判定が REJECT
      return 'この証明書の画像ではチケットを発行できません';
    case 'IMAGE_RETRY': // 解析サーバーの判定が RETRY
      return '画像をうまく確認できませんでした。明るい場所で、証明書全体が写るように撮り直してください';
    case 'ANALYSIS_UPSTREAM_ERROR':
    case 'ANALYSIS_TIMEOUT':
      return 'ただいま混み合っています。時間をおいてお試しください';
    default:
      return '発行できませんでした。もう一度お試しください';
  }
}

export const useTicketStore = defineStore('ticket', () => {
  const config = inject(configKey)!;

  const file = ref<File | null>(null);
  const status = ref<'idle' | 'sending' | 'granted' | 'failed'>('idle');
  const inlineTicket = ref<InlineTicket | null>(null);
  const error = ref<string | null>(null);

  const fileProblem = computed(() => checkFile(file.value));
  const canSend = computed(() => !fileProblem.value && status.value !== 'sending');

  // 送信中の状態とエラーを管理して send を実行する。送信できない状態なら何もしない（二重発行の防止）。
  async function run<T>(send: (file: File) => Promise<T>): Promise<T | undefined> {
    if (!canSend.value || !file.value) return undefined;
    status.value = 'sending';
    error.value = null;
    inlineTicket.value = null;
    try {
      const result = await send(file.value);
      status.value = 'granted';
      return result;
    } catch (err) {
      status.value = 'failed';
      error.value = messageFor(err);
      return undefined;
    }
  }

  // 画面遷移方式（メイン）: 発行して、SPA のチケット画面に移るための { code, sig } を返す。
  async function grantForPage(): Promise<TicketRoute | undefined> {
    const t = await run((f) => postForPage(config.apiBaseUrl, f));
    return t && { code: t.ticketCode, sig: t.sig };
  }

  // その場表示方式（オプション）: 発行して、結果を inlineTicket に入れる。
  async function grantInline(): Promise<void> {
    const t = await run((f) => postInline(config.apiBaseUrl, f));
    if (t) inlineTicket.value = t;
  }

  function reset(): void {
    file.value = null;
    status.value = 'idle';
    inlineTicket.value = null;
    error.value = null;
  }

  return { file, status, inlineTicket, error, fileProblem, canSend, grantForPage, grantInline, reset };
});
