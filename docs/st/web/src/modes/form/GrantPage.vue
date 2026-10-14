<script setup lang="ts">
// フォーム送信方式（オプション）の発行画面: fetch を使わない普通のフォーム。チケット発行 API のリダイレクトで、
// API のチケット表示ページに移る（SPA には戻らない。CORS は不要）。送信前の確認はせず、API に任せる。
// CSP の form-action に送信先を入れておく（web/DEPLOY.md 3.3 の FormActionSource）。
import { inject } from 'vue';
import GrantDescription from '../../components/GrantDescription.vue';
import GrantNotes from '../../components/GrantNotes.vue';
import { configKey } from '../../config.ts';
import { ACCEPT } from '../../stores/ticket.ts';
import { grantFormAction } from './api.ts';

const config = inject(configKey)!;
</script>

<template>
  <main class="mx-auto max-w-sm space-y-6 px-4 py-8">
    <h1 class="text-xl font-bold">チケット発行</h1>
    <GrantDescription />

    <form
      method="post"
      :action="grantFormAction(config.apiBaseUrl)"
      enctype="multipart/form-data"
      class="space-y-4"
      data-testid="post-form"
    >
      <input type="file" name="image" :accept="ACCEPT" required class="block w-full text-sm" />
      <button type="submit" class="w-full rounded-md bg-slate-800 px-4 py-3 text-white">発行する</button>
    </form>

    <!-- フォーム送信方式にはエラーの枠がない（エラーは API のページに出る）ので、ボタンの後 -->
    <GrantNotes />
  </main>
</template>
