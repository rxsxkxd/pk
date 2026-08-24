// hash モード: S3 に直接置いても、リロードや直接アクセスで 404 にならない。画面（ルート）は発行方式ごとに
// 違うので、方式のモジュール（src/modes/<mode>/index.ts）から受け取る。
import { createRouter, createWebHashHistory, type RouterHistory, type RouteRecordRaw } from 'vue-router';

export function createAppRouter(routes: RouteRecordRaw[], history: RouterHistory = createWebHashHistory()) {
  return createRouter({ history, routes: [...routes, { path: '/:pathMatch(.*)*', redirect: '/' }] });
}
