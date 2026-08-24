<script setup lang="ts">
// 全画面（発行画面・チケット画面。iOS / Android 共通）の先頭のバナー。画像は 501×146px で、画面の幅に合わせて縮める
// （width / height を書いておくと、読み込み前から高さが決まり、画面がずれない）。
// 今の画像は仮（src/assets/banner.png）。差し替えるときは、同じ名前・同じ大きさの画像に置き換え、alt も直す。
import banner from '../assets/banner.png';
</script>

<template>
  <header class="mx-auto max-w-sm px-4 pt-6" data-testid="banner">
    <img :src="banner" alt="バナー（仮）" width="501" height="146" class="block h-auto w-full" />
  </header>
</template>
