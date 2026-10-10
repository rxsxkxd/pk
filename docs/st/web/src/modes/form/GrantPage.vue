<script setup lang="ts">
// フォーム送信方式（オプション）の発行画面: fetch を使わない普通のフォーム。チケット発行 API のリダイレクトで、
// API のチケット表示ページに移る（SPA には戻らない。CORS は不要）。送信前の確認はせず、API に任せる。
// CSP の form-action に送信先を入れておく（web/DEPLOY.md 3.3 の FormActionSource）。
import { inject } from 'vue';
import { configKey } from '../../config.ts';
import { ACCEPT } from '../../stores/ticket.ts';
import { grantFormAction } from './api.ts';

const config = inject(configKey)!;
</script>

<template>
  <main class="mx-auto max-w-sm space-y-6 px-4 py-8">
    <h1 class="text-xl font-bold">チケット発行</h1>

    <form
      method="post"
      :action="grantFormAction(config.apiBaseUrl)"
      enctype="multipart/form-data"
      class="space-y-4"
      data-testid="post-form"
    >
      <p class="text-sm text-slate-600">証明書の画像を選んで送ると、チケットの画面に移ります。</p>
      <input type="file" name="image" :accept="ACCEPT" required class="block w-full text-sm" />
      <button type="submit" class="w-full rounded-md bg-slate-800 px-4 py-3 text-white">発行する</button>
    </form>
  </main>
</template>
