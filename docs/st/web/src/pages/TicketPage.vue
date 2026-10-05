<script setup lang="ts">
// SPA のチケット画面（画面遷移方式）。URL のパラメータ（code と sig）だけから描画するので、リロードや
// 共有をしても同じ画面が出る。API の呼び出しは QR 画像 API だけで、再発行はしない。
import { computed, inject, ref } from 'vue';
import { useRoute } from 'vue-router';
import { qrUrl, TicketRouteSchema } from '../api/tickets.ts';
import ErrorMessage from '../components/ErrorMessage.vue';
import TicketCard from '../components/TicketCard.vue';
import { configKey } from '../config.ts';
import { issuedAtFromCode } from '../issuedAt.ts';
import { useTicketStore } from '../stores/ticket.ts';

const config = inject(configKey)!;
const route = useRoute();
const store = useTicketStore();

const ticket = computed(() => TicketRouteSchema.safeParse({ code: route.params.code, sig: route.query.sig }).data);
const qrFailed = ref(false); // QR 画像 API の 403（署名の不一致）や通信エラー。<img> からは区別できない
</script>

<template>
  <main class="mx-auto max-w-sm space-y-6 px-4 py-8 text-center">
    <h1 class="text-xl font-bold">チケット</h1>

    <ErrorMessage v-if="!ticket || qrFailed" message="無効なチケット URL です" />
    <TicketCard
      v-else
      :qr-src="qrUrl(config.apiBaseUrl, ticket.code, ticket.sig)"
      :ticket-code="ticket.code"
      :issued-at="issuedAtFromCode(ticket.code)"
      @qr-error="qrFailed = true"
    />

    <RouterLink to="/" class="inline-block text-sm underline" @click="store.reset()">別の写真で発行する</RouterLink>
  </main>
</template>
