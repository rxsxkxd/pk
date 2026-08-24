<script setup lang="ts">
// QR の表示（画面遷移方式・その場表示方式で共用）。チケットコードと発行日時は画面に出さない（2026-10-13）。
// data-ticket-code は画面に出ない属性で、テストと E2E がどのチケットの QR かを確かめるのに使う。
defineProps<{ qrSrc: string; ticketCode: string }>();
defineEmits<{ qrLoad: []; qrError: [] }>();
</script>

<template>
  <div class="flex flex-col items-center" :data-ticket-code="ticketCode">
    <img
      :src="qrSrc"
      alt="チケットQRコード"
      width="256"
      height="256"
      class="size-64"
      @load="$emit('qrLoad')"
      @error="$emit('qrError')"
    />
  </div>
</template>
