// その場表示方式（オプション）: 発行画面の中に QR を出す（画面は1つ。結果はリロードで消える）。
import type { ModeEntry } from '../types.ts';
import GrantPage from './GrantPage.vue';

export const { mode, routes } = {
  mode: 'inline',
  routes: [{ path: '/', component: GrantPage }],
} satisfies ModeEntry;
