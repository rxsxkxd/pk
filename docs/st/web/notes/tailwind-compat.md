# Tailwind CSS 4 の古いブラウザ向けフォールバックと、3.4 に戻すかの調査

> 2026-10-10 調査。対象は今の SPA（Tailwind CSS 4.3.3、`@tailwindcss/vite`）と、対応ブラウザの要件（../DESIGN.md 2.1。iOS 13 / Android 9）。決めること: ../DESIGN.md 11章の 5。

## 1. 結論

**Tailwind CSS 3.4（`v3-lts`、今は 3.4.19）に戻すのがよい。** 4.1 以降のフォールバックは、Safari 15.4〜16.3 のような「少し古い」ブラウザ向けで、iOS 13 には効かない。Tailwind 4 の出力はすべて `@layer` の中にあり、`@layer` を知らないブラウザ（Safari 15.3 以前）は、Tailwind の CSS を**まるごと無視する**（画面にスタイルが付かない）。これは 4.3.3（2026-07-16）でも変わっていない。

| 案 | iOS 13 での見た目 | 手間・リスク | 評価 |
|---|---|---|---|
| **A: Tailwind 3.4 に戻す** | ほぼそのまま（flex の `gap` だけ別の書き方にする。3章） | 小さい。公式が古いブラウザ向けに勧める方法 | **採る** |
| B: Tailwind 4 のまま、ビルドで変換する | `@layer` と色は直るが、`space-y-*`・`px-*` などはまだ効かない | 大きい。公式の対応外の組み合わせ。CSS が 7割増え、セレクターの詳細度を上げる細工が 400 か所以上入る | 採らない |
| C: Tailwind をやめて CSS を書く | 書き方しだい | 中。使っているユーティリティは 40 個ほどなので書けるが、今の書き方（クラス）をすべて置き換える | 次点 |

- Android 9 だけなら、Chrome 111 以降（2023-03）に上がっていれば Tailwind 4 でも動く。問題は iOS 13〜15.3 と、Chrome 110 以前
- Tailwind の公式の案内: 「古いブラウザに対応する必要があるなら、要件が変わるまで v3.4 を使う」（Upgrade guide）。4.1 のブログも「v4 は今も Safari 16.4 以降のような新しいブラウザ向けに作っている」としている

## 2. Tailwind 4.1 以降のフォールバックの内容

4.1.0（2025-04-01）で入った（公式ブログ「Improved compatibility with older browsers」）。その後の 4.2・4.3 のリリースノートに、古いブラウザ向けの大きな追加はない（`color-mix` のフォールバックの小さな修正だけ）。互換モードの予定は Upgrade guide に「検討中」とあるが、出ていない。

| 4.1 で入ったもの | 効く範囲 |
|---|---|
| `oklab` の色を、古い Safari でも表示する | `@layer` と `oklch()` に対応している Safari 15.4 以降 |
| `@property` で定義する変数（影、変形、グラデーションなど）を、`@property` のないブラウザでも動かす（`@supports` で Safari・Firefox を見分け、変数の初期値を `*` に入れる） | Safari 16.3 以前・Firefox 127 以前。ただし、その初期値も `@layer properties` の中にある |
| 不透明度の修飾子（`bg-red-500/50` など）の色を、`color-mix()` のないブラウザ向けに、計算済みの色で出す | `color-mix()` のない Safari 16.1 以前 |
| 補間の方法を指定したグラデーションを、対応していなければブラウザの既定に戻す | 同上 |

フォールバックはどれも `@layer` の中に出力される。そのため、`@layer` に対応していないブラウザには届かない。

公式の「対応するブラウザ」は 4.0 から変わっていない: Chrome 111、Safari 16.4、Firefox 128 以降。

## 3. 今の SPA のビルド結果で確かめたこと

`web/dist` の CSS（Tailwind 4.3.3）と、比べるために作った2つのビルド（作業用のコピーで作った。リポジトリは変えていない）。

| 調べたもの | 今（4.3.3） | 案 B（4.3.3 + `@csstools/postcss-cascade-layers` + Lightning CSS の変換。対象 Safari 13 / Chrome 80） | 案 A（3.4.19 + autoprefixer） |
|---|---|---|---|
| CSS の大きさ | 8.4KB | 14.2KB | 8.5KB |
| `@layer` | 5 か所（すべてのスタイルが中にある） | 0（`:not(#\#)` を重ねて詳細度で順番を再現。411 か所） | 0 |
| 色 | `oklch()` だけ | 16 進数に変換され、新しいブラウザ向けに `lab()`・`display-p3` も付く | 16 進数と `rgb(r g b / …)` |
| `@property` | 3 | 3（対応していないブラウザは無視するだけ。害はない） | 0 |
| `:where()` | `space-y-*` のセレクターなど | 10（`space-y-*` を含む） | 5（Preflight の一部だけ） |
| 論理プロパティ（`padding-inline` など） | `px-*`・`py-*`・`mx-auto` | 残る（変換されない） | 使わない（`padding-left` など） |
| `::file-selector-button` | そのまま | `::-webkit-file-upload-button` も付く | `::-webkit-file-upload-button` も付く |
| flex の `gap` | `gap-3` | 残る | 残る |

使っている CSS の機能が、どのバージョンから使えるか（MDN の互換性データ 8.1.5）:

| 機能 | iOS Safari | Android Chrome | 今の出力での使われ方 |
|---|---|---|---|
| `@layer` | 15.4 | 99 | **すべてのスタイル** |
| `oklch()` | 15.4 | 111 | すべての色 |
| `color-mix()` | 16.2 | 111 | `@supports` の中だけ |
| `@property` | 16.4 | 85 | 対応していなければ無視される |
| `:where()` / `:is()` | 14 | 88 | `space-y-*`（4）、Preflight の一部（4・3） |
| `margin-inline` / `padding-inline` / `padding-block` | 14.5 | 87 | `mx-auto`・`px-*`・`py-*`（4） |
| flex の `gap` | 14.5 | 84 | `gap-3`（`flex-col` と一緒に2か所） |
| grid の `gap` | 12 | 66 | `grid-cols-2 gap-3`（Android の2つのボタン） |
| `::file-selector-button` | 14.5 | 89 | `file:*`（`-webkit-` 付きの書き方で補える） |
| `rgb(r g b / a)` | 12.2 | 65 | 3.4 の色 |

iOS 13 で 3.4 の出力が効かないのは、次の2つだけ:

- Preflight の `:where()` を使う5つのルール（`abbr[title]`、`input[type=button|reset|submit]`、`[hidden]`）。ボタンの見た目のリセットなどが効かないだけで、画面は崩れない
- flex の `gap`（`TicketCard.vue`・`GrantPage.vue` の `flex flex-col gap-3`）。間隔がなくなる。どの案でも残るので、`space-y-3` に置き換える（3.4 の `space-y-*` は `:where()` を使わない）

## 4. 3.4 に戻すときの作業

| 作業 | 内容 |
|---|---|
| 依存 | `@tailwindcss/vite` と `tailwindcss@4` を外し、`tailwindcss@3.4.19`・`postcss`・`autoprefixer` を入れる（版は固定する） |
| 設定 | `tailwind.config.js`（`content: ['./index.html', './src/**/*.{vue,ts}']`）、`postcss.config.js`（`tailwindcss`・`autoprefixer`）、`vite.config.ts` から `tailwindcss()` を外す |
| 対象ブラウザ | `package.json` の `browserslist`（例: `["ios_saf >= 13", "chrome >= 80"]`。Android の Chrome の下限は ../DESIGN.md 11章の 6 で決める）。autoprefixer が使う。Vite の `build.target` / `build.cssTarget` も合わせる（../DESIGN.md 2.4 の 1） |
| `style.css` | `@import 'tailwindcss';` を `@tailwind base; @tailwind components; @tailwind utilities;` にする |
| クラス | `flex flex-col gap-3` を `flex flex-col space-y-3` にする（2か所）。ほかのクラス（`size-64`、`file:*`、`sr-only`、`max-w-sm`、色）は 3.4 にもある |
| 確認 | `npm run build`・`npm test`、E2E（見た目の確認は Playwright の WebKit では古い Safari を再現できないので、実機かクラウドの実機サービスで行う。../DESIGN.md 2.4 の 7） |
| ドキュメント | ../DESIGN.md 2章の技術スタック、2.4 の 4、6章のファイル構成、11章の 5、../../PAGES.md の技術の行 |

- 3.4 は `v3-lts` として保守されている（npm の dist-tag。最後のリリースは 3.4.19、2025-12-10）。新しい機能は入らない
- 作業用のコピーで、上の設定でビルドが通ることを確かめた（CSS 8.5KB）

## 5. 参考

- Tailwind CSS v4.1 のブログ: https://tailwindcss.com/blog/tailwindcss-v4-1 （「Improved compatibility with older browsers」）
- Compatibility: https://tailwindcss.com/docs/compatibility
- Upgrade guide（Browser requirements）: https://tailwindcss.com/docs/upgrade-guide
- リリースノート: https://github.com/tailwindlabs/tailwindcss/releases
- MDN の互換性データ（`@mdn/browser-compat-data` 8.1.5）
