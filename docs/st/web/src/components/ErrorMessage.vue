<script setup lang="ts">
defineProps<{ message: string }>();
</script>

<template>
  <p role="alert" class="rounded-md bg-red-50 px-4 py-3 text-sm text-red-800" data-testid="error">{{ message }}</p>
</template>
