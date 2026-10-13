# Web フロントエンド 設計

チケット QR API（[../DESIGN.md](../DESIGN.md)）を使う Web フロントエンド。静的ファイルとしてビルドし、S3 に直接、または CloudFront 経由で配信する SPA。

> **状態**: 実装済み（単体テスト 49件。E2E はケース1（画面遷移方式）を Go 版・Node 版の API で通過。../E2E.md）。ただし 2.1 の対応ブラウザ（iOS 13 / Android 9）の要件にはまだ対応しておらず、その実装は保留（2.4）。API 側の前提（チケット付与 API の `Accept: application/json` 対応）は Go 版・Node 版とも実装済み。CORS と Origin の照合（7章）は未実装。
> エンドポイントと画面の名前、API の使い方の3パターンとその評価は [../PAGES.md](../PAGES.md) にまとめてある。
> [../E2E.md](../E2E.md) 3章の「素の HTML / JS の静的サイト」案は、本設計で置き換える。

## 1. 目的と範囲

| 対象 | 内容 |
|---|---|
| 利用者 | スマートフォン（iPhone / Android）のブラウザが主。PC のブラウザも対象 |
| できること | 証明書の画像を選んでチケットを発行し、QR を表示する。**メインは画面遷移方式**（チケット画面を SPA が描画する）。その場表示方式とフォーム送信方式はオプション（3章） |
| 配置 | ビルド結果（HTML / JS / CSS / 設定ファイル）を S3 に置く。サーバー側の処理は持たない |
| 範囲外 | ログイン、チケットの一覧や履歴（API がチケットを保存しないため）、画像の加工（証明書の画像はそのまま送る。上限を超えた写真を縮めることだけは行う。3章） |

SPA の発行方式と、API の使い方（PAGES.md 2章の3パターン）との対応:

| SPA の発行方式 | 位置づけ | API の使い方 | 使う API |
|---|---|---|---|
| **画面遷移方式**（`page`） | **メイン**（ビルドの既定） | パターン2 | チケット付与 API（`Accept: application/json` で JSON を受け取る）→ QR 画像 API（SPA のチケット画面の `<img>`） |
| その場表示方式（`inline`） | オプション | パターン1 | QR 同梱付与 API |
| フォーム送信方式（`form`） | オプション | パターン3 | チケット付与 API（フォーム送信でリダイレクトを受け取る）→ API のチケット表示ページ → QR 画像 API |

- API 側は、3パターンすべてに対応したまま残す（QR 同梱付与 API・チケット付与 API・チケット表示ページ・QR 画像 API）。SPA がオプションを使わない環境でも、API の機能は削らない
- 運用ではどれか1つの方式に決まるので、**方式はビルドのときに選ぶ**（`GRANT_MODE=page|inline|form`。既定は `page`）。1つのビルドには1つの方式のコードだけが入る（4.1、6章）

## 2. 技術スタック

| 項目 | 採用 | 備考 |
|---|---|---|
| ビルド | **Vite** 8 | SPA としてビルドする（`vite build` → `dist/`） |
| UI | **Vue 3.5**（Composition API、`<script setup lang="ts">`） | |
| ルーティング | **vue-router** 5（hash モード） | SPA の発行画面と SPA のチケット画面の2つ。hash モードなので、S3 に直接置いてもリロードや直接アクセスで 404 にならない |
| 状態管理 | **Pinia** 4 | 発行の状態（送信中、結果、エラー）を1つのストアにまとめる（5章） |
| スタイル | **Tailwind CSS 3.4**（3.4.19。`v3-lts`）+ PostCSS + autoprefixer | 2026-10-13 に 4 から戻した（4 は iOS 13〜15.3 でスタイルがまったく付かない。notes/tailwind-compat.md）。`tailwind.config.js`（`content` だけ）、`postcss.config.js`、`src/style.css` は `@tailwind` の3行。autoprefixer の対象は `package.json` の `browserslist`（`ios_saf >= 13`、`chrome >= 80`。Chrome の下限は仮。11章の 6） |
| 検証 | **valibot** 1.5.0（版は固定） | 実行時設定（`config.json`）、API のレスポンス（成功・エラー）、チケット画面の URL パラメータを検証する。2026-10-13 に zod 4 から替えた（zod 4 は読み込み時に `BigInt` を使い、iOS 13 で動かないため。2.4 の 5）。使う関数だけがビルドに入るので小さい（約 7KB） |
| 言語 | TypeScript **6** | 型チェックは `vue-tsc --noEmit`。vue-tsc が TypeScript 7（Go 製のコンパイラー）に対応していないため、Node 版（7）とは違い 6 系に固定する |
| 古いブラウザ向けの補い | **core-js** 3.50.0（版は固定） | 対象のブラウザにない組み込みの関数を補う（今は `Object.hasOwn` だけ。2.4 の 5）。JS は gzip で約 4KB 増える。インストール時のスクリプト（`postinstall`。寄付のお願いを表示するだけ）は許可していない（npm が警告を出すが、動作には影響しない） |
| 画像の縮小 | **Compressor.js** 1.4.0（`compressorjs`。版は固定） | 上限を超えた写真だけを縮めて JPEG にする（3章）。npm の依存は3つに見えるが、`is-blob`・`blueimp-canvas-to-blob` は実行時に使われない（説明は notes/image-compression.md 6.1） |
| テスト | Vitest + `@vue/test-utils` + happy-dom | ストア、API クライアント、コンポーネント。ブラウザでの通しの確認は E2E（Playwright。E2E.md） |

採用しないもの: UI コンポーネントライブラリ（画面が小さく、Tailwind で足りる）、axios（標準の `fetch` で足りる）、ほかの画像の縮小・変換ライブラリ（比較は notes/image-compression.md）。

### 2.1 対応ブラウザ（最低動作バージョン）

> **状態**: 仕様として決定。今の実装はまだこの要件を満たしていない（2.4。実装は保留）。

| OS | 最低バージョン | ブラウザ | 備考 |
|---|---|---|---|
| iOS / iPadOS | **13** | Safari 13（iOS のブラウザはすべて Safari の WebKit を使う） | iOS 13.0〜13.3 の Safari は、`?.`（オプショナルチェーン）と `??` に対応していない（13.4 から）。ビルドで変換する（2.4） |
| Android | **9** | Chrome（Android System WebView を含む） | Chrome の Android 9 向けの更新は Chrome 138 で終わった（Chrome 139 から Android 10 以上）。Android 9 の端末の Chrome は、多くが 138 以下のどこかの版で止まっている。下限の Chrome の版は 11章で決める |

- 上の OS で動けば、それより新しいブラウザ（PC を含む）でも動く
- 「動く」の範囲: 証明書の画像を選んで画面遷移方式で発行し、SPA のチケット画面で QR を表示できること（メインの機能）。オプションの方式と、2.3 のアップロードの進み具合の表示は、対応しないブラウザでは削ってよい

### 2.2 使う Web 機能

iOS 13 / Android 9 で使えるので、そのまま使う（ポリフィルは要らない）。

| 機能 | 用途 | iOS 13（Safari 13） | 補足 |
|---|---|---|---|
| `fetch` | API の呼び出し（発行、`config.json` の取得） | 対応（10.1 から） | |
| `Promise` | 非同期処理 | 対応 | |
| `async` / `await` | 非同期処理の書き方 | 対応（10.1 から） | トップレベルの `await` は **Safari 15 から**なので使わない（`main.ts` は関数の中で `await` する） |
| `AbortController` / `AbortSignal` | 発行のタイムアウトと中断 | 対応（12.1 から） | **`AbortSignal.timeout()` は Safari 16 から**、`AbortSignal.any()` は 17.4 からなので使わない。タイムアウトは `AbortController` と `setTimeout` で作る |

```ts
// タイムアウト付きの fetch（AbortSignal.timeout を使わない）。
async function fetchWithTimeout(url: string, init: RequestInit, ms: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}
```

### 2.3 Fetch Upload Streams（検討中・優先度低）

> **保留（2026-10-12）**: 遅い環境には、上限を超えた写真を縮める処理（3章）のほうが効くので、進み具合は保留にした。以下は保留にする前の案。
>
> **検討中（優先度は低い）**: アップロードの進み具合は、**Android だけ** Fetch Upload Streams で出す案で考えている。iOS の Safari は、最新の正式版（26.x）でも対応していない（開発者向けの Safari Technology Preview 250 で初期の対応をした段階）ので、iOS では進み具合を出さない。将来の Safari の正式版が対応すれば、下の判定で自動的に進み具合が出る。全端末で進み具合を出せる XMLHttpRequest（`xhr.upload.onprogress`）案は、今は採らない。検討の経緯は [notes/upload-progress.md](notes/upload-progress.md)（一時メモ）。この節は、採用が決まったときの仕様の案。

証明書の画像のアップロードの進み具合（％）を出すために、対応ブラウザでは、リクエストのボディを `ReadableStream` で送る（Fetch Upload Streams。`duplex: 'half'`）。対応しないブラウザでは、進み具合の表示を削り、今までどおり `FormData` で送る。

| | 対応ブラウザ | 非対応ブラウザ（フォールバック） |
|---|---|---|
| 対象 | Chrome / Edge 105 以降（Android 9 の Chrome 138 を含む）。将来、正式版が対応した Safari | Safari（iOS 13〜最新の 26.x のすべての版）、Firefox、Chrome 104 以前 |
| 送り方 | `multipart/form-data` のボディを自分で組み立て（boundary、パートのヘッダー、`file.stream()` の中身）、`ReadableStream` で送る。送ったバイト数を数える | `FormData` をそのまま `fetch` に渡す（今の実装） |
| 画面 | 「送信中… 45%」のように進み具合を出す | 「送信中…」だけを出す |
| サーバーが受け取るもの | 同じ（`multipart/form-data` の `image`。証明書の画像は加工しない） | 同じ |

対応の判定（機能の有無で判定し、ブラウザ名では判定しない）:

```ts
// duplex に対応していて、ReadableStream をボディにしたときに Content-Type が付かない（＝ストリームとして扱われる）なら対応。
const supportsRequestStreams = (() => {
  let duplexAccessed = false;
  const hasContentType = new Request('https://example.invalid', {
    body: new ReadableStream(),
    method: 'POST',
    get duplex() {
      duplexAccessed = true;
      return 'half';
    },
  } as RequestInit).headers.has('Content-Type');
  return duplexAccessed && !hasContentType;
})();
```

送信時のフォールバック: 判定で対応していても、ストリームの送信が失敗したとき（下の HTTP/2 の条件など）は、**同じ証明書の画像を `FormData` でもう一度送る**。ストリームで送れなかったことは記録し、そのページを開いている間は、それ以降ストリームを使わない。

制約と注意:

| 項目 | 内容 |
|---|---|
| HTTP/2 以上が必要 | ストリームの送信は HTTP/1.1 では使えない（ボディの長さが事前に分からないため）。サーバーが HTTP/2・HTTP/3 に対応していないと失敗する。**API Gateway HTTP API（execute-api）のエンドポイントが HTTP/2 で応答するかは要確認**（`curl -sI --http2 $API_URL/...` で確かめる）。対応していなければ、常にフォールバックになる。独自ドメインや CloudFront を API の前に置く場合は、そこでも確かめる |
| CORS のプリフライト | オリジンをまたぐストリームの送信は、必ずプリフライト（`OPTIONS`）が発生する（`FormData` の送信は単純リクエストで発生しない）。API Gateway の CORS 設定でプリフライトに応答できるようにする（7章。`AllowMethods` に `POST`、必要なら `AllowHeaders`） |
| 進み具合の精度 | 数えられるのは「ブラウザがストリームから読み出した量」で、ネットワークに送り終えた量ではない（ブラウザ内のバッファーの分だけ先に進む）。目安の表示として使い、100% になっても応答が来るまでは「送信中」とする |
| リダイレクト | ストリームのボディは送り直せないので、リダイレクト（303 以外）されると失敗する。画面遷移方式は 201 の JSON を受け取るので、影響しない |
| 対象 | 画面遷移方式（メイン）とその場表示方式の `fetch` だけ。フォーム送信方式は普通のフォームなので対象外 |

### 2.4 古いブラウザに対応するための実装の変更（1〜5 済み）

必要な変更を次にまとめる。2026-10-13 に 1〜5 を行った。**残りは 6（検討中）と 7（実機での確認）**。

| # | 変更 | 理由 |
|---|---|---|
| 1 | **済み（2026-10-13）**: `vite.config.ts` の `build.target`（と `cssTarget`）を `['safari13', 'chrome80']` にした（Chrome の下限は仮。11章の 6）。`?.`・`??`・`??=`・クラスのフィールドが変換されることを、ビルドの解析で確かめた | Vite 8 の既定の出力先は新しいブラウザ向けで、新しい構文をそのまま出力する |
| 2 | **済み（2026-10-13）**: `src/main.ts` の起動の処理を関数（`start()`）にし、トップレベルの `await` をやめた | トップレベルの `await` は Safari 15 から。変換もできない（ビルドがエラーになる） |
| 3 | **済み（2026-10-13）**: `src/api/client.ts` のタイムアウトを `AbortController` と `setTimeout` にした（応答の読み終わりまでを 30 秒で打ち切り、終わったらタイマーを止める） | `AbortSignal.timeout()` は Safari 16 / Chrome 124 から |
| 4 | **済み（2026-10-13）**: Tailwind CSS 3.4 に戻した（[notes/tailwind-compat.md](notes/tailwind-compat.md)）。あわせて CSS の出力先を `build.cssTarget: ['safari13', 'chrome80']` にした（JS の `build.target` は 1 のまま未対応）。`gap` は使っていない（Android の2つのボタンも、縦並びにしてからは `space-y` で間隔を空ける） | Tailwind CSS 4 は Safari 16.4 / Chrome 111 以降が前提（カスケードレイヤー、`@property`、`color-mix()` などを使う）。出力がすべて `@layer` の中にあるので、Safari 15.3 以前（iOS 13 を含む）ではスタイルがまったく付かない。4.1 以降のフォールバックも `@layer` の中にあり、iOS 13 には効かない。flex の `gap`（Safari 14.5 から）は、どの案でも `space-y-*` に置き換える |
| 5 | **済み（2026-10-13。[notes/builtin-compat.md](notes/builtin-compat.md)）: zod 4（読み込み時に `BigInt` を使い、iOS 13 で JS 全体が止まる）を valibot に替えた。Pinia の `Object.hasOwn` は core-js（`src/main.ts` の先頭で `core-js/actual/object/has-own` だけを読み込む）で補った。Vue の `toSorted()` などは今のコードが呼ばない。ビルドの解析で、ほかに iOS 13 にない機能がないことを確かめた。** もとの項目: 依存ライブラリ（Vue、vue-router、Pinia、zod）のビルド後のコードが、iOS 13 にない組み込みの機能（`Array.prototype.at`、`Object.hasOwn`、`structuredClone` など）を使っていないかを調べる。使っていれば、必要な分だけポリフィルを入れる（`@vitejs/plugin-legacy` の `modernPolyfills`。`renderLegacyChunks: false` にして、CSP に反するインラインのスクリプトを出さない） | 構文はビルドで変換できるが、組み込みの機能は変換されない |
| 6 | （検討中・優先度低）Fetch Upload Streams の送信（2.3）と、Android での送信中の進み具合の表示 | 新しい機能。採用が決まってから行う |
| 7 | 実機での確認: iOS 13 の端末（またはクラウドの実機サービス）と、Android 9 + Chrome 138 以下 | E2E の Playwright の WebKit は最新の WebKit で、Safari 13 の動きは再現しない |

## 3. 画面と操作

| 画面 | ルート | 内容 |
|---|---|---|
| SPA の発行画面 | `#/` | 証明書の画像を選んで発行する。既定は画面遷移方式のボタンだけ。オプションを有効にすると、その場表示方式・フォーム送信方式のボタンも出る |
| SPA のチケット画面 | `#/tickets/{code}?sig={sig}` | 画面遷移方式の結果。URL だけで描画できる（リロード・共有に強い） |

- 各画面の要素と機能の一覧（Android 版・iOS 版）は [SCREENS.md](SCREENS.md)
- **どの画面も、先頭にバナーを出す**（2026-10-13。iOS / Android 共通。`src/components/AppBanner.vue` を `App.vue` に1つ置く）
  - 画像は 501×146px（`src/assets/banner.png`。**今は仮の画像**）。画面の幅に合わせて縦横比を保ったまま縮める（スマートフォンでは 約 350px 幅）。`width` / `height` を書いてあるので、読み込み前から場所が決まり、画面がずれない
  - ビルドで `assets/banner-<ハッシュ>.png` になり、ほかの `assets/*` と同じく長くキャッシュされる。差し替えは、同じ名前・同じ大きさの画像に置き換えてビルドし直す（`alt` の文言も直す）
  - フォーム送信方式のチケットの画面は、API のチケット表示ページ（SPA ではない）なので、バナーは出ない

```
SPA の発行画面 #/（画面遷移方式）           SPA のチケット画面 #/tickets/{code}?sig=…
┌──────────────────────────────┐       ┌──────────────────────────────┐
│ [ バナー 501×146 ]             │       │ [ バナー 501×146 ]             │
│ チケット発行                   │       │ チケット                       │
│ （説明文 約 100 文字）           │       │                              │
│ [ 証明書の画像を選ぶ ]         │       │        ┌────────┐            │
│   ※Android は縦に2つ           │       │        │   QR   │ ← <img>    │
│   [ 画像を選ぶ     ]           │       │        └────────┘（QR 画像 API）│
│   [ カメラを起動   ]           │       │ （チケットの使い方 約 90 文字）  │
│  IMG_0001.HEIC  2.1MB         │       │ [ 別の証明書の画像で発行する ]  │
│ [ 発行する ]                   │       └──────────────────────────────┘
│ ── エラー ──                   │       コードと発行日時は出さない（2026-10-13）
└──────────────────────────────┘
その場表示方式は、同じ発行画面の下に QR を出す（コードと発行日時は出さない）。フォーム送信方式は、発行画面がフォーム1つ
```

### 証明書の画像の選択（共通）

- `accept="image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp"`。`image/heic` を含めると、iPhone が変換せずに HEIC のまま渡すことが期待できる（実機で要確認）
- 形式は拡張子と MIME タイプで目安として確かめる。最終的な判定は API に任せる
- **上限（`config.json` の `maxImageBytes`。既定 4MB。API の上限と同じ値にする）を超えた写真は、選んだときにブラウザで縮める**（`src/image/shrink.ts`。Compressor.js。2026-10-12）
  - 長辺 4096・画質 0.9 から、上限に収まるまで順に試す（4096・0.8 → 3072・0.8 → 2048・0.8）。出力は JPEG（名前も `.jpg`）。写真の向きは直し、EXIF は消える
  - 縮めている間は「画像を縮小しています…」と出し、送れない。縮んだら「縮小しました（11.9MB → 3.4MB）」と出し、縮めた写真を送る
  - どれでも収まらないとき、縮められないとき（デコードできない HEIC など）は、今までどおり「画像のサイズが大きすぎます（4MB まで）」で送れない
  - 縮めている間に別の写真を選んだら、前の結果は捨てる
  - CSP の `img-src` に `blob:` が要る（9章）。ないと縮小に失敗して「大きすぎます」になる
  - フォーム送信方式は対象外（ブラウザがフォームをそのまま送るので、写真を差し替えられない）
- プレビューは出さない（HEIC は多くのブラウザで表示できないため）。ファイル名とサイズだけを出す
- 上限以下の証明書の画像は加工せず、そのまま `FormData` に入れて送る（縮めるのは上限を超えたときだけ）
- **Android だけ、ボタンを2つに分ける**（`src/platform.ts` の `isAndroid`）
  - 理由: Android 14 以降の Chrome では、画像の `<input type="file">` を開くとフォトピッカー（写真の選択）だけが出て、カメラを選べない（Android 13 以前は、選択画面にカメラも出ていた）。iOS の Safari は、選択肢に「写真を撮る」が常に出るので分けない
  - 2つのボタンは縦に並べる（2026-10-13。画面の幅いっぱいのボタンを上下に。「発行する」と同じ高さ）
  - 「画像を選ぶ」: 上と同じ `accept` の選択欄（`capture` なし。フォトピッカーが開く）
  - 「カメラを起動」: `accept="image/*" capture="environment"`（背面のカメラが直接起動する）。`accept` の中に `capture=camera` を書く方法（`accept="image/*;capture=camera"`）は HTML の仕様にない書き方なので使わない
  - 判定: User-Agent Client Hints の `navigator.userAgentData.platform === 'Android'`、または User-Agent に `Android` を含む（どちらかで Android）。`userAgentData.brands` はブラウザの名前（Chromium など）で OS は入っていないので、判定に使わない
  - 2つの選択欄は見た目を隠し（`sr-only`）、`<label>` をボタンの見た目にする。どちらで選んでも、同じ証明書の画像として扱う
  - 参考: <https://qiita.com/caslinden/items/dd6a920b1b9932f3fdcc>

### 画面遷移方式（メイン）: チケット付与 API と QR 画像 API

1. `FormData` で `POST /v1/tickets`（チケット付与 API）に、`Accept: application/json` を付けて `fetch` する
2. 返ってきた `ticketCode` と `sig` で、SPA のチケット画面 `#/tickets/{code}?sig={sig}` に移る（`router.replace`。戻るボタンで発行の直後に戻らないようにする）
3. SPA のチケット画面は URL のパラメータだけから描画する
   - QR: `<img src="{apiBaseUrl}/v1/tickets/{code}/qr?sig={sig}">`（QR 画像 API が署名を照合して PNG を返す）
   - チケットコードと発行日時は、画面に出さない（2026-10-13）。コードは QR の要素の属性 `data-ticket-code` にだけ持つ（テストと E2E で使う）
4. リロードや、URL を保存・共有して開いたときも、同じ画面が出る。API の呼び出しは QR 画像の取得だけで、**再発行されない**
5. `sig` が不正な URL を開くと、QR 画像 API が 403 を返し、`<img>` の読み込みエラーになる。それを検知して「無効なチケット URL です」と表示する

- URL のハッシュ部分（`#` 以降）は、ブラウザが通信で送らない。そのため `<img>` が QR を取りに行くときの Referer に `sig` が含まれない
- 署名付き URL を知っていれば誰でも SPA のチケット画面を開ける（sig に有効期限がないため。API のチケット表示ページと同じ）

### その場表示方式（オプション）: QR 同梱付与 API

1. `FormData` で `POST /v1/tickets/qr-inline`（QR 同梱付与 API）に `fetch` する
2. 返ってきた JSON の QR（base64）を `<img src="data:image/png;base64,…">` で、SPA の発行画面にそのまま表示する。通信は1回で済む
3. 結果は URL に残らない。リロードすると消える（既定では sessionStorage にも残さない。11章）

- 1回きりの表示でよい場面向け。結果が消えることを、画面上で利用者に分かるようにする

### フォーム送信方式（オプション）: チケット付与 API のリダイレクトと、API のチケット表示ページ

1. SPA の発行画面に、`fetch` を使わない普通のフォーム `<form method="post" action="{apiBaseUrl}/v1/tickets" enctype="multipart/form-data">` を出す（`<input type="file" name="image">` を含む）
2. 送信すると、チケット付与 API が `303` で API のチケット表示ページへリダイレクトし、ブラウザはそのまま API のドメインの画面に移る
3. 画面（HTML）は API が返す。QR は、その HTML の `<img>` が QR 画像 API から取る。SPA には戻らない

- `fetch` を使わないので CORS が要らない。CORS の設定前や、`fetch` がうまく動かない環境での代替になる
- 画面のデザインは API 側の HTML（Go・Node）になり、SPA とはそろわない
- SPA 自体は JavaScript で描画するので、JavaScript が使えない環境には、この方式でも対応できない
- 証明書の画像の選択欄はこのフォーム専用のものを使う（`CertificateImagePicker` で選んだファイルを使い回さない）。送信前の確認（上限超えなど）はしない。API がエラーページで知らせる

### 3つの方式の違い

| | 画面遷移方式（メイン） | その場表示方式（オプション） | フォーム送信方式（オプション） |
|---|---|---|---|
| 使う API | チケット付与 API（JSON）→ QR 画像 API | QR 同梱付与 API | チケット付与 API（リダイレクト）→ チケット表示ページ → QR 画像 API |
| 表示までの通信 | 2回 | 1回 | 3回 |
| リロード | URL から再表示できる | 消える | URL から再表示できる |
| URL の共有 | できる | できない | できる |
| 画面を描画するもの | SPA | SPA | API |
| CORS | 必要 | 必要 | 不要 |

各方式の良い点・悪い点の評価は [../PAGES.md](../PAGES.md) 3章にある。

## 4. API との連携

### 4.1 発行方式（ビルド時）と実行時設定（`config.json`）

**発行方式はビルドのときに選ぶ。** 運用ではどれか1つの方式に決まるため。

| `GRANT_MODE` | 方式 | コード |
|---|---|---|
| `page`（既定） | 画面遷移方式（メイン） | `src/modes/page/` |
| `inline` | その場表示方式（オプション） | `src/modes/inline/` |
| `form` | フォーム送信方式（オプション） | `src/modes/form/` |

```sh
npm run build                       # page
GRANT_MODE=inline npm run build     # inline（ローカルの開発も GRANT_MODE=inline npm run dev）
```

- `vite.config.ts` が、別名 `@mode` を `src/modes/$GRANT_MODE/index.ts` に向ける。`main.ts` はそこから画面（ルート）を受け取る。選ばれなかった方式のファイルは、ビルドに入らない（最適化で消えるのを期待するのではなく、そもそも読み込まれない）
- 3つ以外の値はビルドのエラー
- 方式を変えるには、ビルドし直す。CI は3方式ともビルドし（`web-dist-{page,inline,form}`）、デプロイは環境の方式のものを置く（`GRANT_MODE`。CI.md 4章）
- フォーム送信方式は、CloudFront の CSP の `form-action` に送信先を入れる（web/DEPLOY.md 3.3 の `FormActionSource`。9章）

API の URL などは**ビルドに埋め込まず**、起動時に `/config.json` を読み込む。同じ方式のビルド結果を、環境ごとに `config.json` だけ差し替えて配置できるようにするため。

```json
{
  "apiBaseUrl": "https://api.example.com"
}
```

```ts
// src/config.ts
const ConfigSchema = v.object({
  apiBaseUrl: v.pipe(v.union([v.literal(''), v.pipe(v.string(), v.url(), /* http(s) だけ */)]), v.transform((u) => u.replace(/\/+$/, ''))),   // 空文字 = 同じオリジン（統合の構成、開発時のプロキシ。8・9章）
  maxImageBytes: v.optional(v.pipe(v.number(), v.integer(), v.minValue(1), v.maxValue(MAX_IMAGE_BYTES)), MAX_IMAGE_BYTES),  // MAX_IMAGE_BYTES = 4MB
});
```

| キー | 内容 |
|---|---|
| `apiBaseUrl` | API のオリジン。直結の構成では execute-api の URL、統合の構成（CloudFront の `/v1/*` が API）では `""`（同じオリジン） |
| `maxImageBytes` | 画像の上限（バイト。任意、既定 4MB）。API の `MAX_IMAGE_BYTES`（`MaxImageBytes`）と同じ値にする。API までの経路によって上限が下がる場合に使う（../DESIGN.md 5章）。4MB（API の上限）より大きい値は設定のエラー。エラーの文言（「…（2MB まで）」）もこの値から作る |

- 以前の `modes`（実行時に方式を選んでいたときのキー）が残っていても、無視する（エラーにはしない）

### 4.2 API クライアント（共通: `src/api/client.ts`、方式ごと: `src/modes/<方式>/api.ts`）

共通の部分（`postImage`・`ApiError`・コードと署名のスキーマ）と、方式ごとの呼び出しに分ける。

```ts
// src/api/client.ts（共通）: 画像を FormData の image として POST し、201 を schema で解釈する（失敗は ApiError）。
export async function postImage<T>(url: string, file: File, schema: v.GenericSchema<unknown, T>, headers?: Record<string, string>): Promise<T> { … }

// src/modes/page/api.ts
// 画面遷移方式（メイン）: チケット付与 API に画像をそのまま送り、署名付きの QR の URL を返す（Accept: application/json。失敗は ApiError）。
export async function grantForPage(apiBaseUrl: string, file: File): Promise<PageTicket> { … }

// SPA のチケット画面の QR の URL を組み立てる（QR 画像 API）。
export function qrUrl(apiBaseUrl: string, code: string, sig: string): string { … }

// src/modes/inline/api.ts
// その場表示方式（オプション）: QR 同梱付与 API に画像をそのまま送り、QR（base64）付きの発行結果を返す（失敗は ApiError）。
export async function grantInline(apiBaseUrl: string, file: File): Promise<InlineTicket> { … }
```

- フォーム送信方式は `fetch` を使わないので、`src/modes/form/api.ts` は送信先の URL（`grantFormAction`。`{apiBaseUrl}/v1/tickets`）を作るだけ
- `grantForPage` と `grantInline` は、どちらも `FormData` で送る。Content-Type はブラウザが boundary 付きで付ける
- `fetch` の `FormData` 送信は CORS の「単純リクエスト」で、`Accept` ヘッダーを付けても変わらない。そのためプリフライトは発生しない。ただし、レスポンスを読むには API が `Access-Control-Allow-Origin` を返す必要がある（7章）
- タイムアウト: 30秒（API Gateway の上限 29 秒より少し長く）。`AbortController` と `setTimeout` で作る（2.2。2026-10-13 に `AbortSignal.timeout()` から置き換えた）。タイムアウトや通信エラーは「通信できませんでした」として扱う
- （検討中・優先度低）Android（Fetch Upload Streams に対応するブラウザ）だけ、証明書の画像をストリームで送って進み具合を出す案がある。非対応や失敗のときは `FormData` で送る（2.3）
- チケット画面の QR は、`grantForPage` の結果の `qrUrl` ではなく、URL のパラメータから `qrUrl()` で組み立てる（リロード後も同じ方法で描画するため）

### 4.3 検証（valibot）

```ts
import * as v from 'valibot';
const TicketCode = v.pipe(v.string(), v.regex(/^\d{14}[0-9a-f]{32}[A-Za-z0-9]{1,32}$/)); // ../DESIGN.md 4章
const Sig = v.pipe(v.string(), v.regex(/^[A-Za-z0-9_-]{22}$/));
const IssuedAt = v.pipe(v.string(), v.isoTimestamp());   // RFC 3339（API は +09:00 を付ける）
const ApiErrorSchema = v.object({ error: v.object({ code: v.string(), message: v.string() }) });   // ここまで共通（src/api/client.ts）

// 方式ごと（src/modes/inline/api.ts・src/modes/page/api.ts）
const InlineTicketSchema = v.object({
  ticketCode: TicketCode,
  issuedAt: IssuedAt,
  qr: v.object({ mimeType: v.literal('image/png'), data: v.pipe(v.string(), v.base64()) }),
});
const PageTicketSchema = v.object({ ticketCode: TicketCode, issuedAt: IssuedAt, sig: Sig, qrUrl: v.pipe(v.string(), v.url()) });
const TicketRouteSchema = v.object({ code: TicketCode, sig: Sig });   // SPA のチケット画面の URL パラメータ
```

- 成功（201）は各スキーマ、それ以外は `ApiErrorSchema` で解釈する。どちらにも合わなければ「予期しない応答」として扱う
- SPA のチケット画面は、URL のパラメータが `TicketRouteSchema` に合わなければ、API を呼ばずに「無効なチケット URL です」と表示する
- スキーマから型を作る（`v.InferOutput`）ので、画面のコードは検証済みの値だけを扱う
- 検証は `v.parse(schema, 値)`（形が違えば例外）か `v.safeParse(schema, 値)`（結果の `success` と `output`）で行う

### 4.4 エラーの表示

| API のエラーコード | 画面の表示（案） |
|---|---|
| `PAYLOAD_TOO_LARGE`（413） | 画像のサイズが大きすぎます（数字は出さない。API の上限は SPA からは分からず、`config.json` の `maxImageBytes` とずれることもあるため）。送る前の確認（3章）では「画像のサイズが大きすぎます（4MB まで）」と出す（「4MB」は `maxImageBytes` から作る） |
| `UNSUPPORTED_MEDIA_TYPE`（415） | この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP） |
| `IMAGE_REJECTED`（422。解析サーバーの判定が `REJECT`） | この証明書の画像ではチケットを発行できません |
| `IMAGE_RETRY`（422。解析サーバーの判定が `RETRY`） | 画像をうまく確認できませんでした。明るい場所で、証明書全体が写るように撮り直してください |
| `ANALYSIS_UPSTREAM_ERROR`（502）/ `ANALYSIS_TIMEOUT`（504） | ただいま混み合っています。時間をおいてお試しください |
| `BAD_REQUEST`（400） / その他 / 通信エラー | 発行できませんでした。もう一度お試しください |
| SPA のチケット画面の QR が読み込めない（QR 画像 API の 403 など） | 無効なチケット URL です |

画面遷移方式とその場表示方式では、API はエラーを JSON で返す（チケット付与 API は `Accept: application/json` のとき JSON）。フォーム送信方式では、エラーは API のエラーページ（HTML）で表示され、SPA は関わらない。

## 5. 状態管理（Pinia）

```ts
// src/stores/ticket.ts（方式に共通。方式ごとの API の呼び出しは send に渡す）
export const useTicketStore = defineStore('ticket', () => {
  const file = shallowRef<File | null>(null);            // 選んだ写真
  const shrunk = shallowRef<File | null>(null);          // 上限を超えた写真を縮めたもの（3章）
  const shrinking = ref(false);                          // 縮めている間は送れない
  const status = ref<'idle' | 'sending' | 'granted' | 'failed'>('idle');
  const error = ref<string | null>(null);                // 画面に出すメッセージ（4.4）
  // 送る写真は shrunk ?? file。file が変わったら、上限を超えていて対応する形式のときだけ shrinkToFit で縮める

  const fileProblem = computed(() => …);                  // 未選択・上限（maxImageBytes）超え・非対応の拡張子
  async function send<T>(request: (apiBaseUrl: string, file: File) => Promise<T>): Promise<T | undefined> { … }
  function reset() { … }
  return { file, shrunk, shrinking, status, error, fileProblem, canSend, send, reset };
});

// 使い方（src/modes/page/GrantPage.vue）
const t = await store.send(grantForPage);   // 失敗なら undefined（error に文言が入る）
```

- 送信中は、ボタンを押せないようにする（二重発行の防止。`send` は送信中なら何もしない）
- その場表示方式の結果は、その方式の発行画面（`src/modes/inline/GrantPage.vue`）の中だけに持つ
- 画面遷移方式の結果はストアに持たない。SPA のチケット画面は URL だけから描画する
- フォーム送信方式はストアを使わない（ブラウザが API の画面に移るため）
- 設定（`AppConfig`）は起動時に読み込み、`provide` / `inject` で渡す

## 6. ファイル構成

```
st/web/
├── DESIGN.md
├── package.json            # scripts: dev / build / preview / typecheck / test / format
├── vite.config.ts          # @vitejs/plugin-vue、GRANT_MODE → 別名 @mode（4.1）、CSS の対象ブラウザ（cssTarget）、開発時のプロキシ（8章）
├── tailwind.config.js      # Tailwind CSS 3.4 の設定（content だけ）
├── postcss.config.js       # tailwindcss、autoprefixer
├── tsconfig.json           # 型の確認用に @mode を src/modes/page に向ける（ほかの方式は ModeEntry で形を確かめる）
├── index.html
├── public/
│   └── config.json         # ローカル開発用の値（配置時は環境ごとに差し替える）
├── src/
│   ├── main.ts             # 設定を読み込み、Pinia と router（@mode のルート）を入れてマウント
│   ├── App.vue             # <RouterView>
│   ├── router.ts           # hash モード。方式のルートに、知らないパスを / に戻すルートを足す
│   ├── style.css           # @tailwind base / components / utilities
│   ├── config.ts           # config.json の読み込みと検証（valibot）
│   ├── env.d.ts            # vite/client の型
│   ├── platform.ts         # 端末の判定（isAndroid）
│   ├── image/shrink.ts     # 共通: 上限を超えた写真を縮める（Compressor.js。3章）
│   ├── api/client.ts       # 共通: postImage、ApiError、コードと署名のスキーマ（valibot）
│   ├── stores/ticket.ts    # 共通: 発行の状態（Pinia）、送る前の確認と縮小、エラーの文言
│   ├── assets/banner.png   # 先頭のバナーの画像（501×146px。今は仮）
│   ├── components/         # 共通の部品
│   │   ├── AppBanner.vue       # 先頭のバナー（App.vue に1つ。全画面に出る）
│   │   ├── GrantDescription.vue  # 発行画面の説明文（見出しと画像の選択の間。3つの発行方式で共通）
│   │   ├── CertificateImagePicker.vue  # 証明書の画像のファイル選択と送信前の確認（Android は「画像を選ぶ」「カメラを起動」の2つ）
│   │   ├── TicketCard.vue      # QR の表示（画面遷移方式・その場表示方式で共用。コードと発行日時は出さない）
│   │   └── ErrorMessage.vue
│   └── modes/              # 発行方式ごと。ビルドに入るのは GRANT_MODE の1つだけ（4.1）
│       ├── types.ts            # GRANT_MODES、ModeEntry（各方式の index.ts が返す形）
│       ├── page/               # 画面遷移方式（メイン）
│       │   ├── index.ts            # ルート: / と /tickets/:code
│       │   ├── api.ts              # grantForPage、qrUrl、PageTicketSchema、TicketRouteSchema
│       │   ├── GrantPage.vue       # 発行画面（成功したらチケット画面へ）
│       │   └── TicketPage.vue      # SPA のチケット画面（URL から描画。QR の読み込みエラーの表示）
│       ├── inline/             # その場表示方式（オプション）
│       │   ├── index.ts            # ルート: / だけ
│       │   ├── api.ts              # grantInline、InlineTicketSchema
│       │   └── GrantPage.vue       # 発行画面（結果の QR をこの画面に出す）
│       └── form/               # フォーム送信方式（オプション）
│           ├── index.ts            # ルート: / だけ
│           ├── api.ts              # grantFormAction（フォームの送信先）
│           └── GrantPage.vue       # 発行画面（fetch を使わない普通のフォーム）
└── test/                   # Vitest + happy-dom。共通（config / api / store / platform）と、test/modes/（方式ごと。3方式とも1回で流す）
```

- レビューは、共通の部分（`api/client.ts`・`stores/ticket.ts`・`components/`）と、その環境の方式のディレクトリ（`modes/<方式>/`）だけを読めば済む
- 方式を足すときは、`modes/<方式>/` に `index.ts`（`ModeEntry` の形）を作り、`types.ts` の `GRANT_MODES` に足す

## 7. 前提となる API 側の変更

| 変更 | 状態 | 内容 | 必要な理由 |
|---|---|---|---|
| チケット付与 API の `Accept: application/json` 対応 | **実装済み**（Go・Node） | `201 { ticketCode, issuedAt, sig, qrUrl }`、エラーも JSON（DESIGN.md 5.2） | 画面遷移方式（メイン）のため |
| CORS | 未実装（E2E.md 4.3） | QR 同梱付与 API とチケット付与 API のレスポンスに `Access-Control-Allow-Origin: {フロントのオリジン}` を付ける。本番は API Gateway HTTP API の CORS 設定、ローカルは各実装のローカルサーバー | 付けないと、SPA の JS が発行のレスポンスを読めない（フォーム送信方式は不要） |
| Origin の照合 | 未実装（E2E.md 4.2） | QR 同梱付与 API とチケット付与 API で `Origin` を `ALLOWED_ORIGINS` と照合し、違えば 403。フォーム送信方式でも、ブラウザは SPA のオリジンを `Origin` に入れて送る | 他のサイトから発行させないため（CSRF 対策） |
| 設定 | 未実装 | 環境変数 `ALLOWED_ORIGINS`、CloudFormation のパラメータ `AllowedOrigins` | フロントのオリジン（CloudFront のドメイン）を API に教える |

- `<img>` による QR の取得（QR 画像 API）には CORS は不要
- API 側は、SPA が使わない機能（QR 同梱付与 API、チケット表示ページ、フォーム送信のリダイレクト）も含めて、すべて残す

## 8. 開発

```sh
cd docs/st/web
npm ci
npm run dev          # http://localhost:5173
```

- 開発時は Vite のプロキシで `/v1` をローカルの API（`http://localhost:8080`。Go 版 `make run` または Node 版 `npm run dev`）に転送し、`public/config.json` の `apiBaseUrl` を空（同じオリジン）にする。こうすると、7章の CORS が実装されるまでの間も、ローカルでもすべての方式を確かめられる
- ただし API が返す `qrUrl` は API の `PUBLIC_BASE_URL`（`http://localhost:8080`）になる。SPA のチケット画面は `qrUrl()` で `apiBaseUrl` から組み立てるので、プロキシ経由で表示される
- `npm run build` → `dist/`。`npm run preview` でビルド結果を確認する

## 9. 配置（S3 / CloudFront）

| 方式 | 内容 | 評価 |
|---|---|---|
| **CloudFront + S3（推奨）** | S3 は非公開にし、CloudFront の OAC（Origin Access Control）経由でだけ読ませる | HTTPS、独自ドメイン、セキュリティヘッダー（Response Headers Policy）、キャッシュの制御ができる |
| S3 の静的ウェブサイトホスティング | バケットを公開し、ウェブサイトエンドポイントで配信 | 手軽だが **HTTP のみ**（HTTPS にできない）で、ヘッダーも付けられない。検証用に限る |

hash モードのルーティングなので、どちらの方式でも、存在しないパスを `index.html` に向ける設定は不要。

API への経路は、環境ごとに2つから選ぶ（同じ `web.yaml` のパラメータ `ApiOriginDomain` で切り替える。手順は web/DEPLOY.md 3章）。

| 構成 | 経路 | `apiBaseUrl` | CORS | CSP の API の分 |
|---|---|---|---|---|
| 直結 | ブラウザ → API Gateway（別オリジン） | API の URL | 必要 | `img-src`・`connect-src` に `{apiBaseUrl}` |
| 統合 | ブラウザ → CloudFront の `/v1/*` → API Gateway（同じオリジン） | `""` | 不要 | なし（`'self'` で足りる） |

### キャッシュ

| ファイル | Cache-Control | 理由 |
|---|---|---|
| `assets/*`（ハッシュ付きの JS / CSS） | `public, max-age=31536000, immutable` | ファイル名が中身で変わるので、長くキャッシュしてよい |
| `index.html`、`config.json` | `no-cache` | 新しいデプロイや設定をすぐに反映させる |

### セキュリティヘッダー（CloudFront の Response Headers Policy）

直結の場合（統合では `{apiBaseUrl}` の部分がなくなり、`img-src 'self' data: blob:; connect-src 'self'` になる。フォーム送信方式を使うなら `form-action 'self'`）:

```
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self';
  img-src 'self' data: blob: {apiBaseUrl}; connect-src 'self' {apiBaseUrl}; form-action 'none'; frame-ancestors 'none'
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
Strict-Transport-Security: max-age=31536000
```

- `img-src {apiBaseUrl}` は画面遷移方式の QR（QR 画像 API）、`img-src data:` はその場表示方式の QR（data URL）のため。その場表示方式を使わない環境では `data:` を外してよい
- `img-src blob:` と `data:` は、上限を超えた写真を縮めるため（Compressor.js が写真を `blob:` の URL、または JPEG の向きを直すときは `data:` の URL で読み込む。3章）。`blob:` がないと、縮小に失敗して「大きすぎます」になる
- `connect-src 'self'` は、起動時に自分のオリジンの `config.json` を `fetch` するため（`fetch` は `default-src` ではなく `connect-src` で制限され、`connect-src` を書くと `default-src 'self'` は引き継がれない）
- `connect-src {apiBaseUrl}` は、チケット付与 API と QR 同梱付与 API への `fetch` のため
- `form-action` は `default-src` を引き継がないので、明示する。既定は `'none'`（SPA はフォーム送信をしない）。フォーム送信方式（`form`）を有効にする環境だけ `form-action {apiBaseUrl}` にする

### デプロイ手順

手順は [DEPLOY.md](DEPLOY.md)（web/DEPLOY.md）にまとめてある。

- S3 バケット・CloudFront・OAC・Response Headers Policy は、API とは別の CloudFormation テンプレート `infra/cloudformation/web.yaml`（スタック `ticketqr-web-{impl}`）で作る。手動（AWS CLI）の手順もある
- `config.json` は環境ごとに作ってアップロードする。ビルドに含まれる `dist/config.json`（ローカル開発用）はアップロードしない
- 直結では、CloudFront のドメインを、API Gateway の CORS 設定（`AllowOrigins`）に入れる。`api.yaml` にはまだ CORS の設定がないため、今は `aws apigatewayv2 update-api` で設定する（web/DEPLOY.md 5章）
- 統合では CORS は要らない。代わりに、API の `PublicBaseUrl` を CloudFront の URL にする（web/DEPLOY.md 3.2）

## 10. テスト

| 対象 | 方法 |
|---|---|
| `config.ts`、`api/client.ts`・`modes/*/api.ts` のスキーマ | 正しい JSON・欠けた項目・形の違う値を valibot で検証する単体テスト |
| API クライアント | `fetch` を差し替えて、201 / 各エラー / 予期しない応答 / 通信エラーの扱い、画面遷移方式で `Accept: application/json` を付けることを確かめる |
| SPA の発行画面（`test/modes/`） | 方式ごとに、その方式の部品だけが出ること。画面遷移方式はチケット画面へ移ること、その場表示方式は結果をその場に出すこと、フォーム送信方式はフォームの `action` と `enctype`。`test/modes/modes.test.ts` で、`GRANT_MODES` のすべてに `index.ts` と `/` のルートがあることを確かめる |
| 画像の縮小 | `shrinkToFit` の試す順と諦める条件（圧縮の部分は差し替え）。ストアでは、上限以下はそのまま送ること、縮めている間は送れないこと、縮めた写真を送ること、縮められなければ「大きすぎます」、選び直したら前の結果を捨てること（`shrinkToFit` は差し替え）。実際の圧縮は happy-dom に canvas がないので、ブラウザで確かめる（2026-10-12 に Chrome で確認: 11.9MB → 3.4MB、約 0.5 秒。CSP に `blob:` がないと失敗することも確認） |
| ストア | 送信前の確認（未選択、上限超え（`maxImageBytes`）、拡張子）、二重送信の防止、エラーメッセージの対応 |
| SPA のチケット画面 | URL のパラメータの検証、`<img>` の読み込みエラー時の表示、コードと発行日時を画面に出さないこと |
| 通しの確認（**保留中**） | E2E.md の Playwright で、ビルドしたサイト + API（ローカル）を使って、スマートフォン相当の画面幅で操作する。メインの画面遷移方式は必ず確かめ、SPA のチケット画面のリロードで再発行されないことも確かめる。オプションの方式は、その方式でビルドしたもので確かめる（今の E2E は画面遷移方式だけ） |

- 画面の説明文（発行画面の説明文、チケット画面の使い方）は、あとで文言を入れ替える前提なので、テストでは文言の中身は確かめない。置き場所（前後の要素との順番）と、空でないことだけを確かめる

## 11. 決めておきたいこと

決定済み:

| 項目 | 決定 |
|---|---|
| SPA の発行方式 | **画面遷移方式（チケット付与 API ＋ QR 画像 API）をメインにする**。その場表示方式とフォーム送信方式はオプション。**方式はビルドのときに1つ選ぶ**（`GRANT_MODE`。既定は `page`。4.1） |
| API 側の機能 | 3パターンすべてに対応したまま残す（QR 同梱付与 API、チケット付与 API の JSON とリダイレクト、チケット表示ページ、QR 画像 API） |
| チケット付与 API の返し方 | `Accept: application/json` で JSON に切り替える（API 側は実装済み） |
| 対応ブラウザ | iOS 13 / Android 9 以上（2.1）。`fetch`・`Promise`・`async`/`await`・`AbortController`/`AbortSignal` を使う（2.2） |

未確定:

1. その場表示方式（オプション）の結果をリロード後も残すか（sessionStorage）。メインの画面遷移方式があるので、既定では残さない案
2. 配置方式（推奨: CloudFront + 非公開 S3）と、独自ドメインを使うか
3. 7章の API 側の変更（CORS、Origin の照合）を、フロントエンドの実装より先に行ってよいか
4. 画面の文言・デザインの指定（今はシンプルな2画面を想定）
5. スタイルの方式。**2026-10-13: Tailwind CSS 3.4 に戻した（2章、2.4 の 4）**。もとの論点: Tailwind CSS 3.4 にするか、Tailwind を使わずに CSS を書くか（Tailwind CSS 4 は iOS 13 に対応しない。2.4）。調査（2026-10-10）では 3.4（`v3-lts`、3.4.19）を推奨: [notes/tailwind-compat.md](notes/tailwind-compat.md)
6. Android 9 で対応する Chrome の下限の版（Android 9 の Chrome は 138 で更新が止まっている。2.1）
7. （**保留**。2026-10-12: 遅い環境には圧縮のほうが効くので、進み具合の優先度は低い）アップロードの進み具合を Android だけ Fetch Upload Streams で出すか（2.3。notes/upload-progress.md）。出す場合は、API Gateway（execute-api）が HTTP/2 に対応しているかを確かめる（対応していなければ使えない）
8. 証明書の画像をブラウザで圧縮してから送るか。**2026-10-12 に実装: Compressor.js を入れ、上限（`maxImageBytes`）を超えた写真だけを縮める。上限以下の写真は今までどおりそのまま送る（3章、notes/image-compression.md 7.1）**。残り: 画像解析サーバーが縮めた写真で足りるかの確認、iPhone・Android の実機での確認。圧縮するなら、ライブラリ（第一候補: Compressor.js）、長辺・画質、HEIC の扱い。比較は [notes/image-compression.md](notes/image-compression.md)（一時メモ）。圧縮する場合、7 の進み具合は要らなくなる可能性がある
9. （保留）Android の「PC 版サイトを表示」（Chrome・Samsung Internet・Firefox。大画面のタブレットの Chrome は既定でこの表示）では User-Agent から `Android` が消え、「カメラを起動」のボタンが出ない（1つの選択欄になる。3章「証明書の画像の選択」）。対策の案は、判定に `matchMedia('(pointer: coarse)')`（指で操作する端末）を足すこと。ただし iPhone・iPad にもボタンが2つ出る（iPad は Mac を名乗るので、iOS だけ除く判定は外れやすい）ため、影響が大きく保留。PC 版表示で `navigator.userAgentData.platform` と `navigator.platform` が何を返すかは、実機で確かめていない
10. （保留。2026-10-13）画像の大きさのエラーの表示位置をそろえるか。今は、送る前の確認（「画像のサイズが大きすぎます（4MB まで）」）は画像の選択欄の下（`image-problem`）、送ったあとの API の 413（「画像のサイズが大きすぎます」。数字なし）はボタンの下のエラーの枠（`ErrorMessage`）に出る。どちらも同じ写真についてのエラーなので、同じ場所にそろえる案がある
