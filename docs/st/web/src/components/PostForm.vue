<script setup lang="ts">
// フォーム送信方式（オプション）: fetch を使わない普通のフォーム。チケット発行 API のリダイレクトで、
// API のチケット表示ページに移る（SPA には戻らない。CORS は不要）。送信前の確認はせず、API に任せる。
import { ACCEPT } from '../stores/ticket.ts';

defineProps<{ action: string }>();
</script>

<template>
  <form
    method="post"
    :action="action"
    enctype="multipart/form-data"
    class="space-y-2 rounded-md border border-slate-200 p-4"
    data-testid="post-form"
  >
    <p class="text-sm text-slate-600">API の画面でチケットを表示します。</p>
    <input type="file" name="image" :accept="ACCEPT" required class="block w-full text-sm" />
    <button type="submit" class="rounded-md border border-slate-800 px-4 py-2 text-sm">API の画面で表示</button>
  </form>
</template>
