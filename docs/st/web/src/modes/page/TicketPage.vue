<script setup lang="ts">
// SPA のチケット画面（画面遷移方式）。URL のパラメータ（code と sig）だけから描画するので、リロードや
// 共有をしても同じ画面が出る。API の呼び出しは QR 画像 API だけで、再発行はしない。
import * as v from 'valibot';
import { computed, inject, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import ErrorMessage from '../../components/ErrorMessage.vue';
import TicketCard from '../../components/TicketCard.vue';
import { configKey } from '../../config.ts';
import { useTicketStore } from '../../stores/ticket.ts';
import { qrUrl, TicketRouteSchema } from './api.ts';

const config = inject(configKey)!;
const route = useRoute();
const store = useTicketStore();

const ticket = computed(() => {
  const r = v.safeParse(TicketRouteSchema, { code: route.params.code, sig: route.query.sig });
  return r.success ? r.output : undefined;
});
// QR の読み込みの状態。使い方の説明文は、QR が読み込めた（loaded）ときだけ出す。読み込み中に出すと、sig が違う URL
// でも、403 で失敗と分かるまでの間だけ使い方が見えてしまう。failed は QR 画像 API の 403（sig の不一致）や通信エラー
// （<img> からは区別できない）。
const qrState = ref<'loading' | 'loaded' | 'failed'>('loading');
// 同じ画面のまま URL（コードや sig）だけが変わったときは、前の状態を引き継がない。
watch(ticket, () => (qrState.value = 'loading'));
</script>

<template>
  <!-- Spacing per element: the QR image has its own white margin (quiet zone), so it sits close to the heading -->
  <main class="mx-auto max-w-sm px-4 pt-7 pb-8 text-center">
    <h1 class="text-xl font-bold">チケット</h1>

    <ErrorMessage v-if="!ticket || qrState === 'failed'" class="mt-4" message="無効なチケット URL です" />
    <TicketCard
      v-else
      class="mt-1"
      :qr-src="qrUrl(config.apiBaseUrl, ticket.code, ticket.sig)"
      :ticket-code="ticket.code"
      @qr-load="qrState = 'loaded'"
      @qr-error="qrState = 'failed'"
    />
    <!-- チケットの使い方（QR が読み込めたときだけ）。QR の下にも白い余白があるので、上の間隔は小さくする -->
    <p v-if="ticket && qrState === 'loaded'" class="mt-1 text-left text-sm text-slate-600" data-testid="ticket-usage">
      入場のときに、この QR コードを係の人に見せてください。画面を明るくすると読み取りやすくなります。この画面の URL
      を保存しておくと、あとで同じ QR コードを表示できます。
    </p>

    <!-- 画面を移る操作なのでリンクのまま、見た目は発行画面の「発行する」ボタンと同じにする -->
    <RouterLink
      to="/"
      class="mt-4 block w-full rounded-md bg-slate-800 px-4 py-3 text-white"
      data-testid="grant-again"
      @click="store.reset()"
      >別の証明書の画像で発行する</RouterLink
    >
  </main>
</template>
