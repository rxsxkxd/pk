// フォーム送信方式（オプション）: 普通のフォームでチケット発行 API に送り、API のチケット表示ページに移る。
import type { ModeEntry } from '../types.ts';
import GrantPage from './GrantPage.vue';

export const { mode, routes } = {
  mode: 'form',
  routes: [{ path: '/', component: GrantPage }],
} satisfies ModeEntry;
