<script setup lang="ts">
// 証明書の画像の選択。ファイル名とサイズだけを出す（HEIC は多くのブラウザで表示できないので、プレビューは出さない）。
// Android では、画像の選択がフォトピッカーになりカメラを選べない（Android 14 以降）ので、「画像を選ぶ」と
// 「カメラを起動」（capture 付き）の2つのボタンに分ける。ほかの端末（iOS は選択肢にカメラが出る）は1つの選択欄。
import { isAndroid } from '../platform.ts';
import { ACCEPT } from '../stores/ticket.ts';

const file = defineModel<File | null>({ required: true });
defineProps<{ problem?: string; disabled?: boolean }>();

const android = isAndroid();

function onChange(e: Event): void {
  file.value = (e.target as HTMLInputElement).files?.[0] ?? null;
}

function formatSize(bytes: number): string {
  return bytes >= 1 << 20 ? `${(bytes / (1 << 20)).toFixed(1)}MB` : `${Math.ceil(bytes / 1024)}KB`;
}
</script>

<template>
  <div class="space-y-2">
    <div v-if="android" class="grid grid-cols-2 gap-3" data-testid="image-buttons">
      <label
        class="cursor-pointer rounded-md bg-slate-800 px-4 py-2 text-center text-sm text-white has-disabled:cursor-default has-disabled:opacity-40"
      >
        画像を選ぶ
        <input
          type="file"
          :accept="ACCEPT"
          :disabled="disabled"
          data-testid="image-input"
          class="sr-only"
          @change="onChange"
        />
      </label>
      <label
        class="cursor-pointer rounded-md bg-slate-800 px-4 py-2 text-center text-sm text-white has-disabled:cursor-default has-disabled:opacity-40"
      >
        カメラを起動
        <!-- capture は accept が画像のときだけ効く。カメラの撮影結果は JPEG なので image/* で足りる -->
        <input
          type="file"
          accept="image/*"
          capture="environment"
          :disabled="disabled"
          data-testid="camera-input"
          class="sr-only"
          @change="onChange"
        />
      </label>
    </div>
    <label v-else class="block">
      <span class="sr-only">証明書の画像を選ぶ</span>
      <input
        type="file"
        :accept="ACCEPT"
        :disabled="disabled"
        data-testid="image-input"
        class="block w-full text-sm file:mr-3 file:rounded-md file:border-0 file:bg-slate-800 file:px-4 file:py-2 file:text-white"
        @change="onChange"
      />
    </label>
    <p v-if="file" class="text-sm text-slate-600" data-testid="image-info">
      {{ file.name }}　{{ formatSize(file.size) }}
    </p>
    <p v-if="file && problem" class="text-sm text-red-700" data-testid="image-problem">{{ problem }}</p>
  </div>
</template>
