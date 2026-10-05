// 設定（config.json）を読み込み、Pinia と router を入れてマウントする。設定が読めなければ起動しない。
import { createPinia } from 'pinia';
import { createApp } from 'vue';
import App from './App.vue';
import { configKey, loadConfig } from './config.ts';
import { createAppRouter } from './router.ts';
import './style.css';

try {
  const config = await loadConfig();
  createApp(App).provide(configKey, config).use(createPinia()).use(createAppRouter()).mount('#app');
} catch (err) {
  console.error(err);
  document.getElementById('app')!.textContent = '設定を読み込めませんでした。時間をおいて再読み込みしてください。';
}
