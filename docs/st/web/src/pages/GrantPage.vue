<script setup lang="ts">
// SPA の発行画面。既定は画面遷移方式（メイン）のボタンだけ。config.json の modes に応じて、
// その場表示方式とフォーム送信方式（オプション）も出す。
import { computed, inject } from 'vue';
import { useRouter } from 'vue-router';
import { grantFormAction } from '../api/tickets.ts';
import ErrorMessage from '../components/ErrorMessage.vue';
import CertificateImagePicker from '../components/CertificateImagePicker.vue';
import PostForm from '../components/PostForm.vue';
import TicketCard from '../components/TicketCard.vue';
import { configKey } from '../config.ts';
import { formatIssuedAt } from '../issuedAt.ts';
import { useTicketStore } from '../stores/ticket.ts';

const config = inject(configKey)!;
const store = useTicketStore();
const router = useRouter();

const has = (mode: 'page' | 'inline' | 'form') => config.modes.includes(mode);
const sending = computed(() => store.status === 'sending');

// 発行に成功したら SPA のチケット画面へ（replace: 戻るボタンで発行の直後に戻らないようにする）。
async function grantForPage(): Promise<void> {
  const route = await store.grantForPage();
  if (route) await router.replace({ path: `/tickets/${route.code}`, query: { sig: route.sig } });
}
</script>

<template>
  <main class="mx-auto max-w-sm space-y-6 px-4 py-8">
    <h1 class="text-xl font-bold">チケット発行</h1>

    <CertificateImagePicker v-model="store.file" :problem="store.fileProblem" :disabled="sending" />

    <div class="flex flex-col gap-3">
      <button
        v-if="has('page')"
        type="button"
        :disabled="!store.canSend"
        data-testid="grant-page"
        class="rounded-md bg-slate-800 px-4 py-3 text-white disabled:opacity-40"
        @click="grantForPage"
      >
        {{ sending ? '送信中…' : '発行する' }}
      </button>
      <button
        v-if="has('inline')"
        type="button"
        :disabled="!store.canSend"
        data-testid="grant-inline"
        class="rounded-md border border-slate-800 px-4 py-3 disabled:opacity-40"
        @click="store.grantInline()"
      >
        その場で表示
      </button>
    </div>

    <ErrorMessage v-if="store.error" :message="store.error" />

    <section v-if="store.inlineTicket" class="space-y-2" data-testid="inline-result">
      <TicketCard
        :qr-src="`data:${store.inlineTicket.qr.mimeType};base64,${store.inlineTicket.qr.data}`"
        :ticket-code="store.inlineTicket.ticketCode"
        :issued-at="formatIssuedAt(store.inlineTicket.issuedAt)"
      />
      <p class="text-center text-xs text-slate-500">この画面を閉じたり再読み込みしたりすると、表示は消えます。</p>
    </section>

    <PostForm v-if="has('form')" :action="grantFormAction(config.apiBaseUrl)" />
  </main>
</template>
