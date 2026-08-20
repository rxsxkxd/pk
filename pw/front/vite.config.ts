import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  server: {
    proxy: {
      '/api': 'http://api:3000'
    }
  },
  preview: {
    proxy: {
      '/api': 'http://api:3000'
    }
  }
});
