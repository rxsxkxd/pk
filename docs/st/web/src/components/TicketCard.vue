<script setup lang="ts">
// QR・チケットコード・発行日時の表示（画面遷移方式とその場表示方式で共用）。
defineProps<{ qrSrc: string; ticketCode: string; issuedAt: string }>();
defineEmits<{ qrError: [] }>();
</script>

<template>
  <div class="flex flex-col items-center gap-3" :data-ticket-code="ticketCode">
    <img :src="qrSrc" alt="チケットQRコード" width="256" height="256" class="size-64" @error="$emit('qrError')" />
    <p class="font-mono text-lg tracking-wide" data-testid="ticket-code">{{ ticketCode }}</p>
    <p class="text-sm text-slate-600" data-testid="issued-at">発行: {{ issuedAt }}</p>
  </div>
</template>
