// hash モード: S3 に直接置いても、リロードや直接アクセスで 404 にならない。
import { createRouter, createWebHashHistory, type RouterHistory, type RouteRecordRaw } from 'vue-router';
import GrantPage from './pages/GrantPage.vue';
import TicketPage from './pages/TicketPage.vue';

export const routes: RouteRecordRaw[] = [
  { path: '/', component: GrantPage },
  { path: '/tickets/:code', component: TicketPage },
  { path: '/:pathMatch(.*)*', redirect: '/' },
];

export function createAppRouter(history: RouterHistory = createWebHashHistory()) {
  return createRouter({ history, routes });
}
