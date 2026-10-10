// 画面遷移方式（メイン）: 発行画面 → SPA のチケット画面（#/tickets/{code}?sig=…。URL だけから描画する）。
import type { ModeEntry } from '../types.ts';
import GrantPage from './GrantPage.vue';
import TicketPage from './TicketPage.vue';

export const { mode, routes } = {
  mode: 'page',
  routes: [
    { path: '/', component: GrantPage },
    { path: '/tickets/:code', component: TicketPage },
  ],
} satisfies ModeEntry;
