# 依存ライブラリが使う組み込みの機能と、iOS 13 / Android 9 への対応（../DESIGN.md 2.4 の 5）

> **2026-10-13 に対応した**: zod 4 を valibot 1.5.0 に替え、`Object.hasOwn` を core-js で補い、2.4 の 1〜3 も行った。対応後のビルド（画面遷移方式、gzip 50.8KB。zod のときは 73.3KB）を同じ方法で解析し、iOS 13 にない機能で残るのは、今のコードが呼ばない Vue の `toSorted()` などだけになった。以下は対応前の調査

> 2026-10-13 調査。`sh` ブランチ（Tailwind CSS 3.4・画像の圧縮を含む）の画面遷移方式のビルド（`vite build`、今の既定の出力先）を解析した。

## 1. 結論

- **zod 4 が、読み込んだ時点で `BigInt` を使う**（`BigInt("-9223372036854775808")` などの定数を、モジュールの最上位で作る）。`BigInt` は iOS 14 から。**iOS 13 では、JS 全体が読み込みの時点で止まり、画面が真っ白になる**（「設定を読み込めませんでした」も出ない）。ポリフィル（core-js など）では補えない
- ほかに見つかった新しい組み込みの機能は、今のコードが通らない経路にだけある（2章）
- 自前のコードの `AbortSignal.timeout()`（2.4 の 3）は、iOS 16 / **Chrome 124** から。Android 9 の Chrome（138 で更新が止まる）でも、123 以前では動かない
- 対策（3章）: zod を **valibot** か **zod 3** に替える。どちらも読み込み時に `BigInt` を使わない

## 2. 見つかったもの

ビルドした JS を構文として解析し、使われている組み込みの機能を洗い出した。最初に使える版は MDN の互換性データ（`@mdn/browser-compat-data` 8.1.5）、どのライブラリ由来かはソースマップで調べた。構文（`?.`、`??`、`??=`、クラスのフィールド、トップレベルの `await`）は 2.4 の 1・2 で扱うので、ここでは組み込みの機能だけを書く。

| 機能 | iOS Safari | Chrome Android | 使っている場所 | 今のコードで動くか |
|---|---|---|---|---|
| `BigInt` | 14 | 67 | zod（`v4/core/util.js` の `BIGINT_FORMAT_RANGES`） | **iOS 13 で止まる**（読み込み時に必ず動く） |
| `AbortSignal.timeout()` | 16 | 124 | 自前（`src/api/client.ts`） | iOS 13〜15・Chrome 123 以前で、発行の送信が失敗する（2.4 の 3） |
| `Error.captureStackTrace` | 17.2 | 18 | zod | 動く（`"captureStackTrace" in Error` で確かめてから使う） |
| `Array.prototype.toSorted()` / `toReversed()` / `toSpliced()` | 16 | 110 | Vue（`@vue/reactivity` の配列の包み） | 動く（アプリがリアクティブな配列でこれらを呼んだときだけ使われる。今のコードは呼ばない） |
| `Object.hasOwn()` | 15.4 | 93 | Pinia（`$patch` にオブジェクトを渡したとき、SSR の復元のとき） | 動く（今のコードは `$patch` も SSR も使わない）。**`store.$patch({ … })` を使うと、iOS 15.3 以前・Chrome 92 以前で動かなくなる** |
| `globalThis` | 12.2 | 71 | Vue、Pinia、zod、Compressor.js | 動く |
| `Object.fromEntries()` | 12.2 | 73 | zod | 動く |
| `String.prototype.trimStart()`、`Array.prototype.flatMap()` | 12 | 66〜69 | zod | 動く |

調べ方の限界:

- 静的な解析なので、名前を組み立てて呼ぶような使い方は見つけられない。インスタンスのメソッド（`.at()` など）は名前だけで判定している
- 最後は、iOS 13 の実機（またはクラウドの実機サービス）で動かして確かめる（2.4 の 7）

## 3. zod の替え方

同じ程度の検証（オブジェクト、正規表現、URL、日時）を書いて、それぞれをビルドして比べた（esbuild、minify）。

| 候補 | 版 | 読み込み時の `BigInt` | ほかに iOS 13 にない組み込みの機能 | 大きさ（gzip） | 書き換え |
|---|---|---|---|---|---|
| zod 4（今） | 4.6.5 | **ある** | - | 今の JS（約 199KB、minify 後）の 42%（約 84KB）を占める | - |
| zod 4 の `zod/mini` | 4.6.5 | **ある**（同じ部分を使う） | - | - | 解決しない |
| **valibot**（推奨） | 1.5.0 | ない | ない | 約 1.4KB | 中（書き方が違う。`v.object`・`v.pipe(v.string(), v.regex(…))` など。スキーマは `src/config.ts`・`src/api/client.ts`・`src/modes/*/api.ts` の数か所） |
| zod 3 | 3.25.76 | ない（関数の中だけ） | ない | 約 14KB | 小（`z.iso.datetime()` → `z.string().datetime()`、`z.url()` → `z.string().url()`、`z.base64()` → `z.string().base64()` など） |

- `?.` と `??` はどれも使っているが、構文なのでビルドの出力先（2.4 の 1）で変換できる
- ほかの手として、`BigInt` の偽物（呼ばれても数値を返すだけ）を zod より先に読み込ませる方法もあるが、zod の中身に頼った細工になり、`index.html` に別の `<script>` が要る。勧めない
- 推奨は valibot。小さく（今の JS の 42% を占める zod が数 KB になり、JS が大きく減る見込み）、組み込みの機能の問題もない。書き換えを最小にしたいなら zod 3

## 4. 合わせて直すもの（2.4 のほかの項目）

> 2026-10-13: zod の `BigInt` 以外は対応した（下の 1〜3 と、5 の Pinia の `Object.hasOwn`。`Object.hasOwn` は core-js 3.50.0 の `core-js/actual/object/has-own` だけを `src/main.ts` の先頭で読み込んで補う。JS は gzip で約 4KB 増。自前で補う案・補わない案と比べて、説明のしやすさで core-js にした）。対応後のビルドを同じ方法で解析し、残る新しい機能が zod の `BigInt` と、通らない経路のもの（Vue の `toSorted()` など、zod の `Error.captureStackTrace`）だけになったことを確かめた

- 1: ビルドの出力先（`build.target`）を iOS 13 / Chrome（下限は未定）に合わせる。`?.`・`??`・`??=`・クラスのフィールドが変換される
- 2: `src/main.ts` のトップレベルの `await` をやめる（変換できず、ビルドがエラーになる）
- 3: `AbortSignal.timeout()` を `AbortController` と `setTimeout` にする
- 5（この調査）: zod を替える。Pinia の `$patch` にオブジェクトを渡す書き方は使わない（使うなら `Object.hasOwn` のポリフィルが要る）
