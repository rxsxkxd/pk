<script setup lang="ts">
import { onMounted, ref } from 'vue';

const message = ref('Loading API response...');

onMounted(async () => {
  try {
    const response = await fetch('/api/message');
    if (!response.ok) throw new Error('API request failed');
    const data: { message: string } = await response.json();
    message.value = data.message;
  } catch {
    message.value = 'Could not reach the API.';
  }
});
</script>

<template>
  <main>
    <h1>Docker Compose Playwright</h1>
    <p id="api-message" aria-live="polite">{{ message }}</p>
  </main>
</template>
