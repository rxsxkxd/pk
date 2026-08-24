<script setup lang="ts">
// 発行画面の補足事項（「発行する」ボタンとエラーの枠の後。3つの発行方式で共通）。文言は仮で、ここだけで変える。
// 項目を足すときは、この配列に足す。
const notes = [
  '対応している画像の形式は、JPEG / PNG / HEIC / HEIF / AVIF / WebP です。',
  '混み合っているときは、発行に時間がかかったり、発行できなかったりすることがあります。時間をおいてお試しください。',
];
</script>

<template>
  <ul class="list-disc space-y-1 pl-5 text-xs text-slate-500" data-testid="grant-notes">
    <li v-for="note in notes" :key="note">{{ note }}</li>
  </ul>
</template>
