<script setup lang="ts">
// 証明書の画像の選択。ファイル名とサイズだけを出す（HEIC は多くのブラウザで表示できないので、プレビューは出さない）。
import { ACCEPT } from '../stores/ticket.ts';

const file = defineModel<File | null>({ required: true });
defineProps<{ problem?: string; disabled?: boolean }>();

function onChange(e: Event): void {
  file.value = (e.target as HTMLInputElement).files?.[0] ?? null;
}

function formatSize(bytes: number): string {
  return bytes >= 1 << 20 ? `${(bytes / (1 << 20)).toFixed(1)}MB` : `${Math.ceil(bytes / 1024)}KB`;
}
</script>

<template>
  <div class="space-y-2">
    <label class="block">
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
