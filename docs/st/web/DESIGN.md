# Web フロントエンド 設計

チケット QR API（[../DESIGN.md](../DESIGN.md)）を使う Web フロントエンド。静的ファイルとしてビルドし、S3 に直接、または CloudFront 経由で配信する SPA。

> **状態**: 実装済み（単体テスト 43件。ローカルの Go 版 API とプロキシ経由で、3つの方式の通信を確認済み）。ブラウザでの通しの確認（E2E）は保留中。API 側の前提（チケット発行 API の `Accept: application/json` 対応）は Go 版・Node 版とも実装済み。CORS と Origin の照合（7章）は未実装。
> エンドポイントと画面の名前、API の使い方の3パターンとその評価は [../PAGES.md](../PAGES.md) にまとめてある。
> [../E2E.md](../E2E.md) 3章の「素の HTML / JS の静的サイト」案は、本設計で置き換える。

## 1. 目的と範囲

| 対象 | 内容 |
|---|---|
| 利用者 | スマートフォン（iPhone / Android）のブラウザが主。PC のブラウザも対象 |
| できること | 写真を選んでチケットを発行し、QR を表示する。**メインは画面遷移方式**（チケット画面を SPA が描画する）。その場表示方式とフォーム送信方式はオプション（3章） |
| 配置 | ビルド結果（HTML / JS / CSS / 設定ファイル）を S3 に置く。サーバー側の処理は持たない |
| 範囲外 | ログイン、チケットの一覧や履歴（API がチケットを保存しないため）、画像の加工（写真はそのまま送る） |

SPA の発行方式と、API の使い方（PAGES.md 2章の3パターン）との対応:

| SPA の発行方式 | 位置づけ | API の使い方 | 使う API |
|---|---|---|---|
| **画面遷移方式**（`page`） | **メイン**（既定で有効） | パターン2 | チケット発行 API（`Accept: application/json` で JSON を受け取る）→ QR 画像 API（SPA のチケット画面の `<img>`） |
| その場表示方式（`inline`） | オプション | パターン1 | QR 同梱発行 API |
| フォーム送信方式（`form`） | オプション | パターン3 | チケット発行 API（フォーム送信でリダイレクトを受け取る）→ API のチケット表示ページ → QR 画像 API |

- API 側は、3パターンすべてに対応したまま残す（QR 同梱発行 API・チケット発行 API・チケット表示ページ・QR 画像 API）。SPA がオプションを使わない環境でも、API の機能は削らない
- どの方式を出すかは `config.json` の `modes` で決める（4.1）

## 2. 技術スタック

| 項目 | 採用 | 備考 |
|---|---|---|
| ビルド | **Vite** 8 | SPA としてビルドする（`vite build` → `dist/`） |
| UI | **Vue 3.5**（Composition API、`<script setup lang="ts">`） | |
| ルーティング | **vue-router** 5（hash モード） | SPA の発行画面と SPA のチケット画面の2つ。hash モードなので、S3 に直接置いてもリロードや直接アクセスで 404 にならない |
| 状態管理 | **Pinia** 4 | 発行の状態（送信中、結果、エラー）を1つのストアにまとめる（5章） |
| スタイル | **Tailwind CSS** 4（`@tailwindcss/vite`） | `src/style.css` に `@import "tailwindcss";` の1行だけ。設定ファイルは置かない |
| 検証 | **zod** 4 | 実行時設定（`config.json`）、API のレスポンス（成功・エラー）、チケット画面の URL パラメータを検証する |
| 言語 | TypeScript **6** | 型チェックは `vue-tsc --noEmit`。vue-tsc が TypeScript 7（Go 製のコンパイラー）に対応していないため、Node 版（7）とは違い 6 系に固定する |
| テスト | Vitest + `@vue/test-utils` + happy-dom | ストア、API クライアント、コンポーネント。ブラウザでの通しの確認は E2E（Playwright。E2E.md） |

採用しないもの: UI コンポーネントライブラリ（画面が小さく、Tailwind で足りる）、axios（標準の `fetch` で足りる）、画像の縮小・変換ライブラリ（写真はそのまま送る方針）。

## 3. 画面と操作

| 画面 | ルート | 内容 |
|---|---|---|
| SPA の発行画面 | `#/` | 写真を選んで発行する。既定は画面遷移方式のボタンだけ。オプションを有効にすると、その場表示方式・フォーム送信方式のボタンも出る |
| SPA のチケット画面 | `#/tickets/{code}?sig={sig}` | 画面遷移方式の結果。URL だけで描画できる（リロード・共有に強い） |

```
SPA の発行画面 #/                         SPA のチケット画面 #/tickets/20261005135054-4BV81K5V?sig=…
┌──────────────────────────────┐       ┌──────────────────────────────┐
│ チケット発行                    │       │ チケット                        │
│ [ 写真を選ぶ ]                  │       │  ┌────────┐                  │
│  IMG_0001.HEIC  2.1MB          │       │  │  QR    │ ← <img>           │
│ [ 発行する ]  ← 画面遷移方式      │       │  └────────┘  （QR 画像 API）   │
│ ┄ オプション ┄                  │       │  20261005135054-4BV81K5V      │
│ [ その場で表示 ]  ← その場表示方式 │       │  発行: 2026-10-05 13:50:54     │
│ [ API の画面で表示 ] ← フォーム送信 │       │  [ 別の写真で発行する ]          │
│ ── 結果（その場表示方式のとき）── │       └──────────────────────────────┘
│ ── エラー ──                   │
└──────────────────────────────┘
```

### 写真の選択（共通）

- `accept="image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp"`。`image/heic` を含めると、iPhone が変換せずに HEIC のまま渡すことが期待できる（実機で要確認）
- 4MB を超えるファイルは、送る前に知らせる（API の上限と同じ）。形式は拡張子で目安として確かめる。最終的な判定は API に任せる
- プレビューは出さない（HEIC は多くのブラウザで表示できないため）。ファイル名とサイズだけを出す
- 写真は加工せず、そのまま `FormData` に入れて送る

### 画面遷移方式（メイン）: チケット発行 API と QR 画像 API

1. `FormData` で `POST /v1/tickets`（チケット発行 API）に、`Accept: application/json` を付けて `fetch` する
2. 返ってきた `ticketCode` と `sig` で、SPA のチケット画面 `#/tickets/{code}?sig={sig}` に移る（`router.replace`。戻るボタンで発行の直後に戻らないようにする）
3. SPA のチケット画面は URL のパラメータだけから描画する
   - QR: `<img src="{apiBaseUrl}/v1/tickets/{code}/qr?sig={sig}">`（QR 画像 API が署名を照合して PNG を返す）
   - 発行日時: コードの先頭14桁（`YYYYMMDDHHmmss`、日本時間）から表示する
4. リロードや、URL を保存・共有して開いたときも、同じ画面が出る。API の呼び出しは QR 画像の取得だけで、**再発行されない**
5. `sig` が不正な URL を開くと、QR 画像 API が 403 を返し、`<img>` の読み込みエラーになる。それを検知して「無効なチケット URL です」と表示する

- URL のハッシュ部分（`#` 以降）は、ブラウザが通信で送らない。そのため `<img>` が QR を取りに行くときの Referer に `sig` が含まれない
- 署名付き URL を知っていれば誰でも SPA のチケット画面を開ける（sig に有効期限がないため。API のチケット表示ページと同じ）

### その場表示方式（オプション）: QR 同梱発行 API

1. `FormData` で `POST /v1/tickets/qr-inline`（QR 同梱発行 API）に `fetch` する
2. 返ってきた JSON の QR（base64）を `<img src="data:image/png;base64,…">` で、SPA の発行画面にそのまま表示する。通信は1回で済む
3. 結果は URL に残らない。リロードすると消える（既定では sessionStorage にも残さない。11章）

- 1回きりの表示でよい場面向け。結果が消えることを、画面上で利用者に分かるようにする

### フォーム送信方式（オプション）: チケット発行 API のリダイレクトと、API のチケット表示ページ

1. SPA の発行画面に、`fetch` を使わない普通のフォーム `<form method="post" action="{apiBaseUrl}/v1/tickets" enctype="multipart/form-data">` を出す（`<input type="file" name="image">` を含む）
2. 送信すると、チケット発行 API が `303` で API のチケット表示ページへリダイレクトし、ブラウザはそのまま API のドメインの画面に移る
3. 画面（HTML）は API が返す。QR は、その HTML の `<img>` が QR 画像 API から取る。SPA には戻らない

- `fetch` を使わないので CORS が要らない。CORS の設定前や、`fetch` がうまく動かない環境での代替になる
- 画面のデザインは API 側の HTML（Go・Node）になり、SPA とはそろわない
- SPA 自体は JavaScript で描画するので、JavaScript が使えない環境には、この方式でも対応できない
- 写真の選択欄はこのフォーム専用のものを使う（`PhotoPicker` で選んだファイルを使い回さない）。送信前の確認（4MB 超など）はしない。API がエラーページで知らせる

### 3つの方式の違い

| | 画面遷移方式（メイン） | その場表示方式（オプション） | フォーム送信方式（オプション） |
|---|---|---|---|
| 使う API | チケット発行 API（JSON）→ QR 画像 API | QR 同梱発行 API | チケット発行 API（リダイレクト）→ チケット表示ページ → QR 画像 API |
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
// 画面遷移方式（メイン）: チケット発行 API に画像をそのまま送り、署名付きの QR の URL を返す（Accept: application/json。失敗は ApiError）。
export async function issueForPage(apiBaseUrl: string, file: File): Promise<PageTicket> { … }

// SPA のチケット画面の QR の URL を組み立てる（QR 画像 API）。
export function qrUrl(apiBaseUrl: string, code: string, sig: string): string { … }

// その場表示方式（オプション）: QR 同梱発行 API に画像をそのまま送り、QR（base64）付きの発行結果を返す（失敗は ApiError）。
export async function issueInline(apiBaseUrl: string, file: File): Promise<InlineTicket> { … }
```

- フォーム送信方式は `fetch` を使わないので、API クライアントには関数がない（フォームの `action` に `{apiBaseUrl}/v1/tickets` を入れるだけ）
- `issueForPage` と `issueInline` は、どちらも `FormData` で送る。Content-Type はブラウザが boundary 付きで付ける
- `fetch` の `FormData` 送信は CORS の「単純リクエスト」で、`Accept` ヘッダーを付けても変わらない。そのためプリフライトは発生しない。ただし、レスポンスを読むには API が `Access-Control-Allow-Origin` を返す必要がある（7章）
- タイムアウト: `AbortSignal.timeout(30_000)`（API Gateway の上限 29 秒より少し長く）。タイムアウトや通信エラーは「通信できませんでした」として扱う
- チケット画面の QR は、`issueForPage` の結果の `qrUrl` ではなく、URL のパラメータから `qrUrl()` で組み立てる（リロード後も同じ方法で描画するため）

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
| `PAYLOAD_TOO_LARGE`（413） | 写真のサイズが大きすぎます（4MB まで） |
| `UNSUPPORTED_MEDIA_TYPE`（415） | この形式の写真には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP） |
| `IMAGE_INVALID`（422） | この写真ではチケットを発行できません |
| `ANALYSIS_UPSTREAM_ERROR`（502）/ `ANALYSIS_TIMEOUT`（504） | ただいま混み合っています。時間をおいてお試しください |
| `BAD_REQUEST`（400） / その他 / 通信エラー | 発行できませんでした。もう一度お試しください |
| SPA のチケット画面の QR が読み込めない（QR 画像 API の 403 など） | 無効なチケット URL です |

画面遷移方式とその場表示方式では、API はエラーを JSON で返す（チケット発行 API は `Accept: application/json` のとき JSON）。フォーム送信方式では、エラーは API のエラーページ（HTML）で表示され、SPA は関わらない。

## 5. 状態管理（Pinia）

```ts
// src/stores/ticket.ts
export const useTicketStore = defineStore('ticket', () => {
  const file = ref<File | null>(null);
  const status = ref<'idle' | 'sending' | 'issued' | 'failed'>('idle');
  const inlineTicket = ref<InlineTicket | null>(null);   // その場表示方式（オプション）の結果（SPA の発行画面に表示）
  const error = ref<string | null>(null);                // 画面に出すメッセージ（4.4）

  const fileProblem = computed(() => …);                  // 未選択・4MB 超・非対応の拡張子
  async function issueForPage(): Promise<TicketRoute> { … } // 画面遷移方式: 成功したら { code, sig } を返し、画面が SPA のチケット画面へ移る
  async function issueInline() { … }                      // その場表示方式（オプション）
  function reset() { … }
  return { file, status, inlineTicket, error, fileProblem, issueInline, issueForPage, reset };
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
│   │   ├── IssuePage.vue       # SPA の発行画面（写真の選択、画面遷移方式のボタン。modes に応じてオプションの方式も出す）
│   │   └── TicketPage.vue      # SPA のチケット画面（URL から描画。QR の読み込みエラーの表示）
│   └── components/
│       ├── PhotoPicker.vue     # ファイル選択と送信前の確認
│       ├── TicketCard.vue      # QR・コード・発行日時の表示（画面遷移方式・その場表示方式で共用）
│       ├── PostForm.vue        # フォーム送信方式（オプション）の普通のフォーム
│       └── ErrorMessage.vue
└── test/                   # Vitest + happy-dom（helpers.ts、config / api / store / pages のテスト）
```

## 7. 前提となる API 側の変更

| 変更 | 状態 | 内容 | 必要な理由 |
|---|---|---|---|
| チケット発行 API の `Accept: application/json` 対応 | **実装済み**（Go・Node） | `201 { ticketCode, issuedAt, sig, qrUrl }`、エラーも JSON（DESIGN.md 5.2） | 画面遷移方式（メイン）のため |
| CORS | 未実装（E2E.md 4.3） | QR 同梱発行 API とチケット発行 API のレスポンスに `Access-Control-Allow-Origin: {フロントのオリジン}` を付ける。本番は API Gateway HTTP API の CORS 設定、ローカルは各実装のローカルサーバー | 付けないと、SPA の JS が発行のレスポンスを読めない（フォーム送信方式は不要） |
| Origin の照合 | 未実装（E2E.md 4.2） | QR 同梱発行 API とチケット発行 API で `Origin` を `ALLOWED_ORIGINS` と照合し、違えば 403。フォーム送信方式でも、ブラウザは SPA のオリジンを `Origin` に入れて送る | 他のサイトから発行させないため（CSRF 対策） |
| 設定 | 未実装 | 環境変数 `ALLOWED_ORIGINS`、CloudFormation のパラメータ `AllowedOrigins` | フロントのオリジン（CloudFront のドメイン）を API に教える |

- `<img>` による QR の取得（QR 画像 API）には CORS は不要
- API 側は、SPA が使わない機能（QR 同梱発行 API、チケット表示ページ、フォーム送信のリダイレクト）も含めて、すべて残す

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
  img-src 'self' data: {apiBaseUrl}; connect-src {apiBaseUrl}; form-action 'none'; frame-ancestors 'none'
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
Strict-Transport-Security: max-age=31536000
```

- `img-src {apiBaseUrl}` は画面遷移方式の QR（QR 画像 API）、`img-src data:` はその場表示方式の QR（data URL）のため。その場表示方式を使わない環境では `data:` を外してよい
- `connect-src {apiBaseUrl}` は、チケット発行 API と QR 同梱発行 API への `fetch` のため
- `form-action` は `default-src` を引き継がないので、明示する。既定は `'none'`（SPA はフォーム送信をしない）。フォーム送信方式（`form`）を有効にする環境だけ `form-action {apiBaseUrl}` にする

### デプロイ手順（概要）

```sh
npm run build
aws s3 sync dist/ s3://$WEB_BUCKET/ --delete --exclude index.html --exclude config.json \
  --cache-control 'public, max-age=31536000, immutable'
aws s3 cp dist/index.html s3://$WEB_BUCKET/index.html --cache-control no-cache
aws s3 cp config/$ENV.json s3://$WEB_BUCKET/config.json --cache-control no-cache   # 環境ごとの設定
aws cloudfront create-invalidation --distribution-id $DIST_ID --paths /index.html /config.json
```

- S3 バケット・CloudFront・OAC・Response Headers Policy は、CloudFormation テンプレート（`web/infra/template.yaml`）として用意する（実装時）
- CloudFront のドメインを、API の `AllowedOrigins`（7章）に設定する

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
| SPA の発行方式 | **画面遷移方式（チケット発行 API ＋ QR 画像 API）をメインにする**。その場表示方式とフォーム送信方式はオプション（`config.json` の `modes` で有効にする。既定は無効） |
| API 側の機能 | 3パターンすべてに対応したまま残す（QR 同梱発行 API、チケット発行 API の JSON とリダイレクト、チケット表示ページ、QR 画像 API） |
| チケット発行 API の返し方 | `Accept: application/json` で JSON に切り替える（API 側は実装済み） |

未確定:

1. その場表示方式（オプション）の結果をリロード後も残すか（sessionStorage）。メインの画面遷移方式があるので、既定では残さない案
2. 配置方式（推奨: CloudFront + 非公開 S3）と、独自ドメインを使うか
3. 7章の API 側の変更（CORS、Origin の照合）を、フロントエンドの実装より先に行ってよいか
4. 画面の文言・デザインの指定（今はシンプルな2画面を想定）
