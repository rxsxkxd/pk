// 設定（config.json）を読み込み、Pinia と router を入れてマウントする。設定が読めなければ起動しない。
// 発行方式はビルド時に決まる（'@mode' = src/modes/$GRANT_MODE。vite.config.ts）。
// 対象のブラウザ（iOS 13 / Android 9）にない組み込みの関数を、ライブラリが使う前に補う（core-js。必要な機能だけ）。
// Object.hasOwn: iOS 15.4 / Chrome 93 から。Pinia が $patch（オブジェクトを渡したとき）で使う（notes/builtin-compat.md）。
import 'core-js/actual/object/has-own';
import { routes } from '@mode';
import { createPinia } from 'pinia';
import { createApp } from 'vue';
import App from './App.vue';
import { configKey, loadConfig } from './config.ts';
import { createAppRouter } from './router.ts';
import './style.css';

// トップレベルの await は使わない（Safari 15 から。ビルドで変換もできない。DESIGN.md 2.4）。
async function start(): Promise<void> {
  try {
    const config = await loadConfig();
    createApp(App).provide(configKey, config).use(createPinia()).use(createAppRouter(routes)).mount('#app');
  } catch (err) {
    console.error(err);
    document.getElementById('app')!.textContent = '設定を読み込めませんでした。時間をおいて再読み込みしてください。';
  }
}

void start();
