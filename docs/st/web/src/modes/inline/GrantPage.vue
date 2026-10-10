<script setup lang="ts">
// その場表示方式（オプション）の発行画面。発行に成功したら、この画面の中に QR を出す。結果は保存しない
// （閉じたり再読み込みしたりすると消える）。
import { computed, ref } from 'vue';
import CertificateImagePicker from '../../components/CertificateImagePicker.vue';
import ErrorMessage from '../../components/ErrorMessage.vue';
import TicketCard from '../../components/TicketCard.vue';
import { formatIssuedAt } from '../../issuedAt.ts';
import { useTicketStore } from '../../stores/ticket.ts';
import { grantInline, type InlineTicket } from './api.ts';

const store = useTicketStore();
const sending = computed(() => store.status === 'sending');
const ticket = ref<InlineTicket | null>(null);

async function grant(): Promise<void> {
  if (!store.canSend) return; // 送信中のもう1回の押下で、前の結果を消さない
  ticket.value = null;
  ticket.value = (await store.send(grantInline)) ?? null;
}
</script>

<template>
  <main class="mx-auto max-w-sm space-y-6 px-4 py-8">
    <h1 class="text-xl font-bold">チケット発行</h1>

    <CertificateImagePicker v-model="store.file" :problem="store.fileProblem" :disabled="sending" />

    <button
      type="button"
      :disabled="!store.canSend"
      data-testid="grant-inline"
      class="w-full rounded-md bg-slate-800 px-4 py-3 text-white disabled:opacity-40"
      @click="grant"
    >
      {{ sending ? '送信中…' : '発行する' }}
    </button>

    <ErrorMessage v-if="store.error" :message="store.error" />

    <section v-if="ticket" class="space-y-2" data-testid="inline-result">
      <TicketCard
        :qr-src="`data:${ticket.qr.mimeType};base64,${ticket.qr.data}`"
        :ticket-code="ticket.ticketCode"
        :issued-at="formatIssuedAt(ticket.issuedAt)"
      />
      <p class="text-center text-xs text-slate-500">この画面を閉じたり再読み込みしたりすると、表示は消えます。</p>
    </section>
  </main>
</template>
