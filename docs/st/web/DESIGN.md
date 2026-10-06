# Web フロントエンド 設計

チケット QR API（[../DESIGN.md](../DESIGN.md)）を使う Web フロントエンド。静的ファイルとしてビルドし、S3 に直接、または CloudFront 経由で配信する SPA。

> **状態**: 実装済み（単体テスト 43件。E2E はケース1（画面遷移方式）を Go 版・Node 版の API で通過。../E2E.md）。ただし 2.1 の対応ブラウザ（iOS 13 / Android 9）の要件にはまだ対応しておらず、その実装は保留（2.4）。API 側の前提（チケット付与 API の `Accept: application/json` 対応）は Go 版・Node 版とも実装済み。CORS と Origin の照合（7章）は未実装。
> エンドポイントと画面の名前、API の使い方の3パターンとその評価は [../PAGES.md](../PAGES.md) にまとめてある。
> [../E2E.md](../E2E.md) 3章の「素の HTML / JS の静的サイト」案は、本設計で置き換える。

## 1. 目的と範囲

| 対象 | 内容 |
|---|---|
| 利用者 | スマートフォン（iPhone / Android）のブラウザが主。PC のブラウザも対象 |
| できること | 証明書の画像を選んでチケットを発行し、QR を表示する。**メインは画面遷移方式**（チケット画面を SPA が描画する）。その場表示方式とフォーム送信方式はオプション（3章） |
| 配置 | ビルド結果（HTML / JS / CSS / 設定ファイル）を S3 に置く。サーバー側の処理は持たない |
| 範囲外 | ログイン、チケットの一覧や履歴（API がチケットを保存しないため）、画像の加工（証明書の画像はそのまま送る） |

SPA の発行方式と、API の使い方（PAGES.md 2章の3パターン）との対応:

| SPA の発行方式 | 位置づけ | API の使い方 | 使う API |
|---|---|---|---|
| **画面遷移方式**（`page`） | **メイン**（既定で有効） | パターン2 | チケット付与 API（`Accept: application/json` で JSON を受け取る）→ QR 画像 API（SPA のチケット画面の `<img>`） |
| その場表示方式（`inline`） | オプション | パターン1 | QR 同梱付与 API |
| フォーム送信方式（`form`） | オプション | パターン3 | チケット付与 API（フォーム送信でリダイレクトを受け取る）→ API のチケット表示ページ → QR 画像 API |

- API 側は、3パターンすべてに対応したまま残す（QR 同梱付与 API・チケット付与 API・チケット表示ページ・QR 画像 API）。SPA がオプションを使わない環境でも、API の機能は削らない
- どの方式を出すかは `config.json` の `modes` で決める（4.1）

## 2. 技術スタック

| 項目 | 採用 | 備考 |
|---|---|---|
| ビルド | **Vite** 8 | SPA としてビルドする（`vite build` → `dist/`） |
| UI | **Vue 3.5**（Composition API、`<script setup lang="ts">`） | |
| ルーティング | **vue-router** 5（hash モード） | SPA の発行画面と SPA のチケット画面の2つ。hash モードなので、S3 に直接置いてもリロードや直接アクセスで 404 にならない |
| 状態管理 | **Pinia** 4 | 発行の状態（送信中、結果、エラー）を1つのストアにまとめる（5章） |
| スタイル | **Tailwind CSS** 4（`@tailwindcss/vite`） | `src/style.css` に `@import "tailwindcss";` の1行だけ。設定ファイルは置かない。**iOS 13 に対応しないため見直す（2.4、11章）** |
| 検証 | **zod** 4 | 実行時設定（`config.json`）、API のレスポンス（成功・エラー）、チケット画面の URL パラメータを検証する |
| 言語 | TypeScript **6** | 型チェックは `vue-tsc --noEmit`。vue-tsc が TypeScript 7（Go 製のコンパイラー）に対応していないため、Node 版（7）とは違い 6 系に固定する |
| テスト | Vitest + `@vue/test-utils` + happy-dom | ストア、API クライアント、コンポーネント。ブラウザでの通しの確認は E2E（Playwright。E2E.md） |

採用しないもの: UI コンポーネントライブラリ（画面が小さく、Tailwind で足りる）、axios（標準の `fetch` で足りる）、画像の縮小・変換ライブラリ（証明書の画像はそのまま送る方針）。

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

### 2.4 古いブラウザに対応するための実装の変更（保留）

今の実装は、2.1 の要件を満たしていない。必要な変更を次にまとめる（**実装は保留**）。

| # | 変更 | 理由 |
|---|---|---|
| 1 | Vite の `build.target` を iOS 13 / Android 9 の Chrome に合わせる（例: `['es2019', 'safari13']`） | Vite 8 の既定のターゲットは新しいブラウザ（Safari 16 以降など）向けで、`?.` や `??` をそのまま出力する |
| 2 | `main.ts` のトップレベルの `await` をやめ、関数の中で `await` する | トップレベルの `await` は Safari 15 から。変換もできない（ビルドがエラーになる） |
| 3 | `AbortSignal.timeout()` を、`AbortController` と `setTimeout` に置き換える（2.2） | Safari 16 から |
| 4 | **Tailwind CSS 4 をやめる**（Tailwind CSS 3.4 にするか、Tailwind を使わずに CSS を書く。11章で決める） | Tailwind CSS 4 は Safari 16.4 / Chrome 111 以降が前提（カスケードレイヤー、`@property`、`color-mix()` などを使う）。iOS 13 では見た目が大きく崩れる |
| 5 | 依存ライブラリ（Vue、vue-router、Pinia、zod）のビルド後のコードが、iOS 13 にない組み込みの機能（`Array.prototype.at`、`Object.hasOwn`、`structuredClone` など）を使っていないかを調べる。使っていれば、必要な分だけポリフィルを入れる（`@vitejs/plugin-legacy` の `modernPolyfills`。`renderLegacyChunks: false` にして、CSP に反するインラインのスクリプトを出さない） | 構文はビルドで変換できるが、組み込みの機能は変換されない |
| 6 | （検討中・優先度低）Fetch Upload Streams の送信（2.3）と、Android での送信中の進み具合の表示 | 新しい機能。採用が決まってから行う |
| 7 | 実機での確認: iOS 13 の端末（またはクラウドの実機サービス）と、Android 9 + Chrome 138 以下 | E2E の Playwright の WebKit は最新の WebKit で、Safari 13 の動きは再現しない |

## 3. 画面と操作

| 画面 | ルート | 内容 |
|---|---|---|
| SPA の発行画面 | `#/` | 証明書の画像を選んで発行する。既定は画面遷移方式のボタンだけ。オプションを有効にすると、その場表示方式・フォーム送信方式のボタンも出る |
| SPA のチケット画面 | `#/tickets/{code}?sig={sig}` | 画面遷移方式の結果。URL だけで描画できる（リロード・共有に強い） |

```
SPA の発行画面 #/                         SPA のチケット画面 #/tickets/20261005135054-4BV81K5V?sig=…
┌──────────────────────────────┐       ┌──────────────────────────────┐
│ チケット発行                    │       │ チケット                        │
│ [ 証明書の画像を選ぶ ]          │       │  ┌────────┐                  │
│  IMG_0001.HEIC  2.1MB          │       │  │  QR    │ ← <img>           │
│ [ 発行する ]  ← 画面遷移方式      │       │  └────────┘  （QR 画像 API）   │
│ ┄ オプション ┄                  │       │  20261005135054-4BV81K5V      │
│ [ その場で表示 ]  ← その場表示方式 │       │  発行: 2026-10-05 13:50:54     │
│ [ API の画面で表示 ] ← フォーム送信 │       │  [ 別の証明書の画像で発行する ]  │
│ ── 結果（その場表示方式のとき）── │       └──────────────────────────────┘
│ ── エラー ──                   │
└──────────────────────────────┘
```

### 証明書の画像の選択（共通）

- `accept="image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp"`。`image/heic` を含めると、iPhone が変換せずに HEIC のまま渡すことが期待できる（実機で要確認）
- 4MB を超えるファイルは、送る前に知らせる（API の上限と同じ）。形式は拡張子で目安として確かめる。最終的な判定は API に任せる
- プレビューは出さない（HEIC は多くのブラウザで表示できないため）。ファイル名とサイズだけを出す
- 証明書の画像は加工せず、そのまま `FormData` に入れて送る

### 画面遷移方式（メイン）: チケット付与 API と QR 画像 API

1. `FormData` で `POST /v1/tickets`（チケット付与 API）に、`Accept: application/json` を付けて `fetch` する
2. 返ってきた `ticketCode` と `sig` で、SPA のチケット画面 `#/tickets/{code}?sig={sig}` に移る（`router.replace`。戻るボタンで発行の直後に戻らないようにする）
3. SPA のチケット画面は URL のパラメータだけから描画する
   - QR: `<img src="{apiBaseUrl}/v1/tickets/{code}/qr?sig={sig}">`（QR 画像 API が署名を照合して PNG を返す）
   - 発行日時: コードの先頭14桁（`YYYYMMDDHHmmss`、日本時間）から表示する
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
- 証明書の画像の選択欄はこのフォーム専用のものを使う（`CertificateImagePicker` で選んだファイルを使い回さない）。送信前の確認（4MB 超など）はしない。API がエラーページで知らせる

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

### 4.1 実行時設定（`config.json`）

API の URL などは**ビルドに埋め込まず**、起動時に `/config.json` を読み込む。同じビルド結果を、環境ごとに `config.json` だけ差し替えて配置できるようにするため。

```json
{
  "apiBaseUrl": "https://api.example.com",
  "modes": ["page"]
}
```

```ts
// src/config.ts
const ConfigSchema = z.object({
  apiBaseUrl: z.string().transform((u) => u.replace(/\/+$/, '')),   // 空文字 = 同じオリジン（開発時のプロキシ。8章）
  modes: z.array(z.enum(['page', 'inline', 'form'])).min(1).default(['page']),
});
```

| `modes` の値 | 方式 | 既定 |
|---|---|---|
| `page` | 画面遷移方式（メイン） | 有効 |
| `inline` | その場表示方式（オプション） | 無効 |
| `form` | フォーム送信方式（オプション） | 無効 |

- 既定は `["page"]`。オプションを使う環境だけ、`config.json` に `"inline"` や `"form"` を足す
- `form` を有効にするときは、CloudFront の CSP の `form-action` を `{apiBaseUrl}` にする（9章）

### 4.2 API クライアント（`src/api/tickets.ts`）

```ts
// 画面遷移方式（メイン）: チケット付与 API に画像をそのまま送り、署名付きの QR の URL を返す（Accept: application/json。失敗は ApiError）。
export async function grantForPage(apiBaseUrl: string, file: File): Promise<PageTicket> { … }

// SPA のチケット画面の QR の URL を組み立てる（QR 画像 API）。
export function qrUrl(apiBaseUrl: string, code: string, sig: string): string { … }

// その場表示方式（オプション）: QR 同梱付与 API に画像をそのまま送り、QR（base64）付きの発行結果を返す（失敗は ApiError）。
export async function grantInline(apiBaseUrl: string, file: File): Promise<InlineTicket> { … }
```

- フォーム送信方式は `fetch` を使わないので、API クライアントには関数がない（フォームの `action` に `{apiBaseUrl}/v1/tickets` を入れるだけ）
- `grantForPage` と `grantInline` は、どちらも `FormData` で送る。Content-Type はブラウザが boundary 付きで付ける
- `fetch` の `FormData` 送信は CORS の「単純リクエスト」で、`Accept` ヘッダーを付けても変わらない。そのためプリフライトは発生しない。ただし、レスポンスを読むには API が `Access-Control-Allow-Origin` を返す必要がある（7章）
- タイムアウト: 30秒（API Gateway の上限 29 秒より少し長く）。`AbortController` と `setTimeout` で作る（2.2。今の実装の `AbortSignal.timeout()` は iOS 13 で使えないので置き換える）。タイムアウトや通信エラーは「通信できませんでした」として扱う
- （検討中・優先度低）Android（Fetch Upload Streams に対応するブラウザ）だけ、証明書の画像をストリームで送って進み具合を出す案がある。非対応や失敗のときは `FormData` で送る（2.3）
- チケット画面の QR は、`grantForPage` の結果の `qrUrl` ではなく、URL のパラメータから `qrUrl()` で組み立てる（リロード後も同じ方法で描画するため）

### 4.3 検証（zod）

```ts
const TicketCode = z.string().regex(/^\d{14}-[0-9A-HJKMNP-TV-Z]+$/);
const Sig = z.string().regex(/^[A-Za-z0-9_-]{22}$/);

const InlineTicketSchema = z.object({
  ticketCode: TicketCode,
  issuedAt: z.iso.datetime({ offset: true }),
  qr: z.object({ mimeType: z.literal('image/png'), data: z.base64() }),
});
const PageTicketSchema = z.object({ ticketCode: TicketCode, issuedAt: z.iso.datetime({ offset: true }), sig: Sig, qrUrl: z.url() });
const ApiErrorSchema = z.object({ error: z.object({ code: z.string(), message: z.string() }) });
const TicketRouteSchema = z.object({ code: TicketCode, sig: Sig });   // SPA のチケット画面の URL パラメータ
```

- 成功（201）は各スキーマ、それ以外は `ApiErrorSchema` で解釈する。どちらにも合わなければ「予期しない応答」として扱う
- SPA のチケット画面は、URL のパラメータが `TicketRouteSchema` に合わなければ、API を呼ばずに「無効なチケット URL です」と表示する
- スキーマから型を作る（`z.infer`）ので、画面のコードは検証済みの値だけを扱う

### 4.4 エラーの表示

| API のエラーコード | 画面の表示（案） |
|---|---|
| `PAYLOAD_TOO_LARGE`（413） | 画像のサイズが大きすぎます（4MB まで） |
| `UNSUPPORTED_MEDIA_TYPE`（415） | この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP） |
| `IMAGE_INVALID`（422） | この証明書の画像ではチケットを発行できません |
| `ANALYSIS_UPSTREAM_ERROR`（502）/ `ANALYSIS_TIMEOUT`（504） | ただいま混み合っています。時間をおいてお試しください |
| `BAD_REQUEST`（400） / その他 / 通信エラー | 発行できませんでした。もう一度お試しください |
| SPA のチケット画面の QR が読み込めない（QR 画像 API の 403 など） | 無効なチケット URL です |

画面遷移方式とその場表示方式では、API はエラーを JSON で返す（チケット付与 API は `Accept: application/json` のとき JSON）。フォーム送信方式では、エラーは API のエラーページ（HTML）で表示され、SPA は関わらない。

## 5. 状態管理（Pinia）

```ts
// src/stores/ticket.ts
export const useTicketStore = defineStore('ticket', () => {
  const file = ref<File | null>(null);
  const status = ref<'idle' | 'sending' | 'granted' | 'failed'>('idle');
  const inlineTicket = ref<InlineTicket | null>(null);   // その場表示方式（オプション）の結果（SPA の発行画面に表示）
  const error = ref<string | null>(null);                // 画面に出すメッセージ（4.4）

  const fileProblem = computed(() => …);                  // 未選択・4MB 超・非対応の拡張子
  async function grantForPage(): Promise<TicketRoute> { … } // 画面遷移方式: 成功したら { code, sig } を返し、画面が SPA のチケット画面へ移る
  async function grantInline() { … }                      // その場表示方式（オプション）
  function reset() { … }
  return { file, status, inlineTicket, error, fileProblem, grantInline, grantForPage, reset };
});
```

- 送信中は、すべてのボタンを押せないようにする（二重発行の防止）
- 画面遷移方式の結果はストアに持たない。SPA のチケット画面は URL だけから描画する
- フォーム送信方式はストアを使わない（ブラウザが API の画面に移るため）
- 設定（`AppConfig`）は起動時に読み込み、`provide` / `inject` で渡す

## 6. ファイル構成

```
st/web/
├── DESIGN.md
├── package.json            # scripts: dev / build / preview / typecheck / test / format
├── vite.config.ts          # @vitejs/plugin-vue、@tailwindcss/vite、開発時のプロキシ（8章）
├── tsconfig.json
├── index.html
├── public/
│   └── config.json         # ローカル開発用の値。すべての方式を確かめられるよう modes は3つとも有効（配置時は環境ごとに差し替える）
├── src/
│   ├── main.ts             # 設定を読み込み、Pinia と router を入れてマウント
│   ├── App.vue             # <RouterView>
│   ├── router.ts           # hash モード。#/ と #/tickets/:code
│   ├── style.css           # @import "tailwindcss";
│   ├── config.ts           # config.json の読み込みと検証（zod）
│   ├── issuedAt.ts         # 発行日時の表示（コードの先頭14桁、API の issuedAt から）
│   ├── env.d.ts            # vite/client の型
│   ├── api/tickets.ts      # API クライアント、スキーマ（zod）、ApiError
│   ├── stores/ticket.ts    # 発行の状態（Pinia）
│   ├── pages/
│   │   ├── GrantPage.vue       # SPA の発行画面（証明書の画像の選択、画面遷移方式のボタン。modes に応じてオプションの方式も出す）
│   │   └── TicketPage.vue      # SPA のチケット画面（URL から描画。QR の読み込みエラーの表示）
│   └── components/
│       ├── CertificateImagePicker.vue  # 証明書の画像のファイル選択と送信前の確認
│       ├── TicketCard.vue      # QR・コード・発行日時の表示（画面遷移方式・その場表示方式で共用）
│       ├── PostForm.vue        # フォーム送信方式（オプション）の普通のフォーム
│       └── ErrorMessage.vue
└── test/                   # Vitest + happy-dom（helpers.ts、config / api / store / pages のテスト）
```

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

### キャッシュ

| ファイル | Cache-Control | 理由 |
|---|---|---|
| `assets/*`（ハッシュ付きの JS / CSS） | `public, max-age=31536000, immutable` | ファイル名が中身で変わるので、長くキャッシュしてよい |
| `index.html`、`config.json` | `no-cache` | 新しいデプロイや設定をすぐに反映させる |

### セキュリティヘッダー（CloudFront の Response Headers Policy）

```
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self';
  img-src 'self' data: {apiBaseUrl}; connect-src 'self' {apiBaseUrl}; form-action 'none'; frame-ancestors 'none'
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
Strict-Transport-Security: max-age=31536000
```

- `img-src {apiBaseUrl}` は画面遷移方式の QR（QR 画像 API）、`img-src data:` はその場表示方式の QR（data URL）のため。その場表示方式を使わない環境では `data:` を外してよい
- `connect-src 'self'` は、起動時に自分のオリジンの `config.json` を `fetch` するため（`fetch` は `default-src` ではなく `connect-src` で制限され、`connect-src` を書くと `default-src 'self'` は引き継がれない）
- `connect-src {apiBaseUrl}` は、チケット付与 API と QR 同梱付与 API への `fetch` のため
- `form-action` は `default-src` を引き継がないので、明示する。既定は `'none'`（SPA はフォーム送信をしない）。フォーム送信方式（`form`）を有効にする環境だけ `form-action {apiBaseUrl}` にする

### デプロイ手順

手順は [DEPLOY.md](DEPLOY.md)（web/DEPLOY.md）にまとめてある。

- S3 バケット・CloudFront・OAC・Response Headers Policy は、API とは別の CloudFormation テンプレート `infra/cloudformation/web.yaml`（スタック `ticketqr-web-{impl}`）で作る。手動（AWS CLI）の手順もある
- `config.json` は環境ごとに作ってアップロードする。ビルドに含まれる `dist/config.json`（ローカル開発用）はアップロードしない
- CloudFront のドメインを、API Gateway の CORS 設定（`AllowOrigins`）に入れる。`api.yaml` にはまだ CORS の設定がないため、今は `aws apigatewayv2 update-api` で設定する（web/DEPLOY.md 5章）

## 10. テスト

| 対象 | 方法 |
|---|---|
| `config.ts`、`api/tickets.ts` のスキーマ | 正しい JSON・欠けた項目・形の違う値を zod で検証する単体テスト |
| API クライアント | `fetch` を差し替えて、201 / 各エラー / 予期しない応答 / 通信エラーの扱い、画面遷移方式で `Accept: application/json` を付けることを確かめる |
| SPA の発行画面 | `modes` の値に応じて、出るボタンが変わること（既定は画面遷移方式だけ）。フォーム送信方式のフォームの `action` と `enctype` |
| ストア | 送信前の確認（未選択、4MB 超、拡張子）、二重送信の防止、エラーメッセージの対応 |
| SPA のチケット画面 | URL のパラメータの検証、`<img>` の読み込みエラー時の表示、コードからの発行日時の表示 |
| 通しの確認（**保留中**） | E2E.md の Playwright で、ビルドしたサイト + API（ローカル）を使って、スマートフォン相当の画面幅で操作する。メインの画面遷移方式は必ず確かめ、SPA のチケット画面のリロードで再発行されないことも確かめる。オプションの方式は、`modes` で有効にした設定でも確かめる |

## 11. 決めておきたいこと

決定済み:

| 項目 | 決定 |
|---|---|
| SPA の発行方式 | **画面遷移方式（チケット付与 API ＋ QR 画像 API）をメインにする**。その場表示方式とフォーム送信方式はオプション（`config.json` の `modes` で有効にする。既定は無効） |
| API 側の機能 | 3パターンすべてに対応したまま残す（QR 同梱付与 API、チケット付与 API の JSON とリダイレクト、チケット表示ページ、QR 画像 API） |
| チケット付与 API の返し方 | `Accept: application/json` で JSON に切り替える（API 側は実装済み） |
| 対応ブラウザ | iOS 13 / Android 9 以上（2.1）。`fetch`・`Promise`・`async`/`await`・`AbortController`/`AbortSignal` を使う（2.2） |

未確定:

1. その場表示方式（オプション）の結果をリロード後も残すか（sessionStorage）。メインの画面遷移方式があるので、既定では残さない案
2. 配置方式（推奨: CloudFront + 非公開 S3）と、独自ドメインを使うか
3. 7章の API 側の変更（CORS、Origin の照合）を、フロントエンドの実装より先に行ってよいか
4. 画面の文言・デザインの指定（今はシンプルな2画面を想定）
5. スタイルの方式: Tailwind CSS 3.4 にするか、Tailwind を使わずに CSS を書くか（Tailwind CSS 4 は iOS 13 に対応しない。2.4）
6. Android 9 で対応する Chrome の下限の版（Android 9 の Chrome は 138 で更新が止まっている。2.1）
7. （優先度低）アップロードの進み具合を Android だけ Fetch Upload Streams で出すか（2.3）。出す場合は、API Gateway（execute-api）が HTTP/2 に対応しているかを確かめる（対応していなければ使えない）
8. 証明書の画像をブラウザで圧縮してから送るか（今は「証明書の画像は加工せずに送る」方針）。圧縮するなら、ライブラリ（第一候補: Compressor.js）、長辺・画質、HEIC の扱い。比較は [notes/image-compression.md](notes/image-compression.md)（一時メモ）。圧縮する場合、7 の進み具合は要らなくなる可能性がある
