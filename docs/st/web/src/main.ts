// 設定（config.json）を読み込み、Pinia と router を入れてマウントする。設定が読めなければ起動しない。
// 発行方式はビルド時に決まる（'@mode' = src/modes/$GRANT_MODE。vite.config.ts）。
import { routes } from '@mode';
import { createPinia } from 'pinia';
import { createApp } from 'vue';
import App from './App.vue';
import { configKey, loadConfig } from './config.ts';
import { createAppRouter } from './router.ts';
import './style.css';

try {
  const config = await loadConfig();
  createApp(App).provide(configKey, config).use(createPinia()).use(createAppRouter(routes)).mount('#app');
} catch (err) {
  console.error(err);
  document.getElementById('app')!.textContent = '設定を読み込めませんでした。時間をおいて再読み込みしてください。';
}
