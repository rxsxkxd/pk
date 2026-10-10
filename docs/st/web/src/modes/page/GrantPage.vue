<script setup lang="ts">
// 画面遷移方式（メイン）の発行画面。発行に成功したら、SPA のチケット画面に移る。
import { computed } from 'vue';
import { useRouter } from 'vue-router';
import CertificateImagePicker from '../../components/CertificateImagePicker.vue';
import ErrorMessage from '../../components/ErrorMessage.vue';
import { useTicketStore } from '../../stores/ticket.ts';
import { grantForPage } from './api.ts';

const store = useTicketStore();
const router = useRouter();
const sending = computed(() => store.status === 'sending');

// replace: 戻るボタンで発行の直後に戻らないようにする。
async function grant(): Promise<void> {
  const t = await store.send(grantForPage);
  if (t) await router.replace({ path: `/tickets/${t.ticketCode}`, query: { sig: t.sig } });
}
</script>

<template>
  <main class="mx-auto max-w-sm space-y-6 px-4 py-8">
    <h1 class="text-xl font-bold">チケット発行</h1>

    <CertificateImagePicker v-model="store.file" :problem="store.fileProblem" :disabled="sending" />

    <button
      type="button"
      :disabled="!store.canSend"
      data-testid="grant-page"
      class="w-full rounded-md bg-slate-800 px-4 py-3 text-white disabled:opacity-40"
      @click="grant"
    >
      {{ sending ? '送信中…' : '発行する' }}
    </button>

    <ErrorMessage v-if="store.error" :message="store.error" />
  </main>
</template>
