// Grant state shared by the grant modes (DESIGN.md 5): the chosen photo, the photo to send (shrunk when it is
// over the limit, notes/image-compression.md 7.1), sending / failed and the message to show. What a grant
// returns is up to each mode (src/modes/<mode>/), which passes its API call to send().

import { defineStore } from 'pinia';
import { computed, inject, ref, shallowRef, watch } from 'vue';
import { ApiError } from '../api/client.ts';
import { configKey, MAX_IMAGE_BYTES } from '../config.ts';
import { shrinkToFit } from '../image/shrink.ts';

// Same formats as the API (the size limit is config.json's maxImageBytes); the API makes the final
// decision from the file's content.
export const ACCEPT = 'image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp';
const EXTENSIONS = /\.(jpe?g|png|heic|heif|avif|webp)$/i;

// バイト数を画面に出す大きさにする（例: 4MB、1.5MB、512KB）。
export function sizeLabel(bytes: number): string {
  if (bytes < 1 << 20) return `${Math.floor(bytes / 1024)}KB`;
  return `${Math.floor((bytes / (1 << 20)) * 10) / 10}MB`;
}

function tooLarge(maxBytes: number): string {
  return `画像のサイズが大きすぎます（${sizeLabel(maxBytes)} まで）`;
}

// 対応する形式か（MIME タイプか拡張子で目安として確かめる。最終的な判定は API）。
export function isAcceptedImage(file: File): boolean {
  return ACCEPT.split(',').includes(file.type) || EXTENSIONS.test(file.name);
}

// 送信前に分かる問題を返す（なければ undefined）。
export function checkFile(file: File | null, maxBytes = MAX_IMAGE_BYTES): string | undefined {
  if (!file) return '証明書の画像を選んでください';
  if (file.size > maxBytes) return tooLarge(maxBytes);
  if (!isAcceptedImage(file)) {
    return 'この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）';
  }
  return undefined;
}

// API のエラーを画面に出す文言にする（DESIGN.md 4.4）。
export function messageFor(err: unknown): string {
  switch (err instanceof ApiError ? err.code : '') {
    case 'PAYLOAD_TOO_LARGE': // API の上限は SPA からは分からない（config.json とずれることもある）ので、数字は出さない
      return '画像のサイズが大きすぎます';
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

  // shallowRef: a File is passed to FormData as it is, never wrapped in a reactive proxy.
  const file = shallowRef<File | null>(null); // 選んだ写真
  const shrunk = shallowRef<File | null>(null); // 上限を超えた写真を縮めたもの（縮められたときだけ）
  const shrinking = ref(false);
  const status = ref<'idle' | 'sending' | 'granted' | 'failed'>('idle');
  const error = ref<string | null>(null);

  // 送る写真: 縮めたものがあればそれ、なければ選んだ写真そのもの（上限以下ならそのまま送る）。
  const upload = computed(() => shrunk.value ?? file.value);
  const fileProblem = computed(() => (shrinking.value ? undefined : checkFile(upload.value, config.maxImageBytes)));
  const canSend = computed(() => !shrinking.value && !fileProblem.value && status.value !== 'sending');
  // ボタンの下のエラーの枠に出す文言（1か所にまとめる）。選んだ写真の問題（大きすぎる、形式が違う）を先に、
  // なければ API のエラー。写真を選ぶ前は「選んでください」を出さない（ボタンが押せないことで分かる）。
  const errorMessage = computed(() => (file.value ? fileProblem.value : undefined) ?? error.value ?? undefined);

  // 写真を選んだら、前の API のエラーを消す（新しい写真には関係ないため）。上限を超えていて対応する形式の
  // ときだけ縮める。縮めている間に別の写真を選んだら、前の結果は捨てる。sync: 選んだ直後から shrinking に
  // して、その間に送れないようにする。
  let selection = 0;
  watch(
    file,
    async (chosen) => {
      const current = ++selection;
      error.value = null;
      shrunk.value = null;
      shrinking.value = false;
      if (!chosen || chosen.size <= config.maxImageBytes || !isAcceptedImage(chosen)) return;
      shrinking.value = true;
      const result = await shrinkToFit(chosen, config.maxImageBytes);
      if (current !== selection) return;
      shrunk.value = result ?? null;
      shrinking.value = false;
    },
    { flush: 'sync' },
  );

  // 選んだ画像で request（方式ごとの API の呼び出し）を実行し、送信中の状態とエラーを管理する。
  // 送信できない状態なら何もしない（二重発行の防止）。失敗したら undefined を返し、error に文言を入れる。
  async function send<T>(request: (apiBaseUrl: string, file: File) => Promise<T>): Promise<T | undefined> {
    if (!canSend.value || !upload.value) return undefined;
    status.value = 'sending';
    error.value = null;
    try {
      const result = await request(config.apiBaseUrl, upload.value);
      status.value = 'granted';
      return result;
    } catch (err) {
      status.value = 'failed';
      error.value = messageFor(err);
      return undefined;
    }
  }

  function reset(): void {
    file.value = null;
    status.value = 'idle';
    error.value = null;
  }

  return { file, shrunk, shrinking, status, error, fileProblem, canSend, errorMessage, send, reset };
});
