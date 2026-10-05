# Web フロントエンド 設計

チケット QR API（[../DESIGN.md](../DESIGN.md)）を使う Web フロントエンド。静的ファイルとしてビルドし、S3 に直接、または CloudFront 経由で配信する SPA。

> **状態**: 設計のみ（未実装）。API 側の前提（B-1 の `Accept: application/json` 対応）は Go 版・Node 版とも実装済み。CORS と Origin の照合（7章）は未実装。
> [../E2E.md](../E2E.md) 3章の「素の HTML / JS の静的サイト」案は、本設計で置き換える。

## 1. 目的と範囲

| 対象 | 内容 |
|---|---|
| 利用者 | スマートフォン（iPhone / Android）のブラウザが主。PC のブラウザも対象 |
| できること | 写真を選んでチケットを発行し、QR を表示する。チケット画面は **SPA が描画する**（2つの方式。3章） |
| 配置 | ビルド結果（HTML / JS / CSS / 設定ファイル）を S3 に置く。サーバー側の処理は持たない |
| 範囲外 | ログイン、チケットの一覧や履歴（API がチケットを保存しないため）、画像の加工（写真はそのまま送る） |

API のエンドポイントとの対応:

| API | SPA での使い方 |
|---|---|
| A `POST /v1/tickets/qr-inline` | 方式A: 発行して、QR（base64）を受け取り、その場で表示する |
| B-1 `POST /v1/tickets`（`Accept: application/json`） | 方式B: 発行して、署名付きの QR の URL を受け取る |
| B-2 `GET /v1/tickets/{code}/qr?sig=…` | 方式B: チケット画面の `<img>` が QR を取得する |
| B-3 `GET /v1/tickets/{code}/view?sig=…` | **使わない**（API が HTML を返す画面。SPA を使わない利用のために API 側に残す） |

## 2. 技術スタック

| 項目 | 採用 | 備考 |
|---|---|---|
| ビルド | **Vite** 8 | SPA としてビルドする（`vite build` → `dist/`） |
| UI | **Vue 3.5**（Composition API、`<script setup lang="ts">`） | |
| ルーティング | **vue-router** 5（hash モード） | 発行画面とチケット画面の2つ。hash モードなので、S3 に直接置いてもリロードや直接アクセスで 404 にならない |
| 状態管理 | **Pinia** 4 | 発行の状態（送信中、結果、エラー）を1つのストアにまとめる（5章） |
| スタイル | **Tailwind CSS** 4（`@tailwindcss/vite`） | `src/style.css` に `@import "tailwindcss";` の1行だけ。設定ファイルは置かない |
| 検証 | **zod** 4 | 実行時設定（`config.json`）、API のレスポンス（成功・エラー）、チケット画面の URL パラメータを検証する |
| 言語 | TypeScript | 型チェックは `vue-tsc --noEmit` |
| テスト | Vitest + `@vue/test-utils` + happy-dom | ストア、API クライアント、コンポーネント。ブラウザでの通しの確認は E2E（Playwright。E2E.md） |

採用しないもの: UI コンポーネントライブラリ（画面が小さく、Tailwind で足りる）、axios（標準の `fetch` で足りる）、画像の縮小・変換ライブラリ（写真はそのまま送る方針）。

## 3. 画面と操作

| 画面 | ルート | 内容 |
|---|---|---|
| 発行画面 | `#/` | 写真を選び、方式A または方式B で発行する |
| チケット画面 | `#/tickets/{code}?sig={sig}` | 方式B の結果。URL だけで描画できる（リロード・共有に強い） |

```
発行画面 #/                              チケット画面 #/tickets/20261005135054-4BV81K5V?sig=…
┌──────────────────────────────┐       ┌──────────────────────────────┐
│ チケット発行                    │       │ チケット                        │
│ [ 写真を選ぶ ]                  │       │  ┌────────┐                  │
│  IMG_0001.HEIC  2.1MB          │       │  │  QR    │ ← <img src=qrUrl> │
│ [ 発行して表示（A） ]            │       │  └────────┘    （B-2 から取得） │
│ [ チケット画面へ（B） ]           │       │  20261005135054-4BV81K5V      │
│ ── 結果（A のとき）──           │       │  発行: 2026-10-05 13:50:54     │
│  QR / コード / 発行日時          │       │  [ 別の写真で発行する ]          │
│ ── エラー ──                   │       └──────────────────────────────┘
└──────────────────────────────┘
```

### 写真の選択（共通）

- `accept="image/jpeg,image/png,image/heic,image/heif,image/avif,image/webp"`。`image/heic` を含めると、iPhone が変換せずに HEIC のまま渡すことが期待できる（実機で要確認）
- 4MB を超えるファイルは、送る前に知らせる（API の上限と同じ）。形式は拡張子で目安として確かめる。最終的な判定は API に任せる
- プレビューは出さない（HEIC は多くのブラウザで表示できないため）。ファイル名とサイズだけを出す
- 写真は加工せず、そのまま `FormData` に入れて送る

### 方式A: 発行して、その場で表示

1. `FormData` で `POST /v1/tickets/qr-inline` に `fetch` する
2. 返ってきた JSON の QR（base64）を `<img src="data:image/png;base64,…">` で表示する。通信は1回で済む
3. 結果は発行画面に出すだけで、URL には残らない。リロードすると消える（既定では sessionStorage にも残さない。9章）

### 方式B: 発行して、チケット画面へ

1. `FormData` で `POST /v1/tickets` に、`Accept: application/json` を付けて `fetch` する
2. 返ってきた `ticketCode` と `sig` で、チケット画面 `#/tickets/{code}?sig={sig}` に移る（`router.replace`。戻るボタンで発行の直後に戻らないようにする）
3. チケット画面は URL のパラメータだけから描画する
   - QR: `<img src="{apiBaseUrl}/v1/tickets/{code}/qr?sig={sig}">`（B-2 が署名を照合して PNG を返す）
   - 発行日時: コードの先頭14桁（`YYYYMMDDHHmmss`、日本時間）から表示する
4. リロードや、URL を保存・共有して開いたときも、同じ画面が出る。API の呼び出しは QR 画像の取得だけで、**再発行されない**
5. `sig` が不正な URL を開くと、B-2 が 403 を返し、`<img>` の読み込みエラーになる。それを検知して「無効なチケット URL です」と表示する

- URL のハッシュ部分（`#` 以降）は、ブラウザが通信で送らない。そのため `<img>` が QR を取りに行くときの Referer に `sig` が含まれない
- 署名付き URL を知っていれば誰でもチケット画面を開ける（sig に有効期限がないため。API 側の B-3 と同じ）

### 方式A と方式B の違い

| | 方式A | 方式B |
|---|---|---|
| 使う API | A | B-1（JSON）+ B-2 |
| QR の受け取り方 | JSON に base64 で埋め込み（通信1回） | `<img>` で別に取得（通信2回） |
| リロード | 消える | URL から再表示できる |
| URL の共有 | できない | できる |

両方のボタンを出すか、どちらかだけにするかは、`config.json` の `modes` で切り替える（4.1）。

## 4. API との連携

### 4.1 実行時設定（`config.json`）

API の URL などは**ビルドに埋め込まず**、起動時に `/config.json` を読み込む。同じビルド結果を、環境ごとに `config.json` だけ差し替えて配置できるようにするため。

```json
{
  "apiBaseUrl": "https://api.example.com",
  "modes": ["inline", "page"]
}
```

```ts
// src/config.ts
const ConfigSchema = z.object({
  apiBaseUrl: z.string().transform((u) => u.replace(/\/+$/, '')),   // 空文字 = 同じオリジン（開発時のプロキシ。8章）
  modes: z.array(z.enum(['inline', 'page'])).min(1).default(['inline', 'page']),
});
```

### 4.2 API クライアント（`src/api/tickets.ts`）

```ts
// 方式A: 画像をそのまま送り、QR（base64）付きの発行結果を返す（失敗は ApiError）。
export async function issueInline(apiBaseUrl: string, file: File): Promise<InlineTicket> { … }

// 方式B: 画像をそのまま送り、署名付きの QR の URL を返す（Accept: application/json。失敗は ApiError）。
export async function issueForPage(apiBaseUrl: string, file: File): Promise<PageTicket> { … }

// チケット画面の QR の URL を組み立てる（B-2）。
export function qrUrl(apiBaseUrl: string, code: string, sig: string): string { … }
```

- どちらも `FormData` で送る。Content-Type はブラウザが boundary 付きで付ける
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
const TicketRouteSchema = z.object({ code: TicketCode, sig: Sig });   // チケット画面の URL パラメータ
```

- 成功（201）は各スキーマ、それ以外は `ApiErrorSchema` で解釈する。どちらにも合わなければ「予期しない応答」として扱う
- チケット画面は、URL のパラメータが `TicketRouteSchema` に合わなければ、API を呼ばずに「無効なチケット URL です」と表示する
- スキーマから型を作る（`z.infer`）ので、画面のコードは検証済みの値だけを扱う

### 4.4 エラーの表示

| API のエラーコード | 画面の表示（案） |
|---|---|
| `PAYLOAD_TOO_LARGE`（413） | 写真のサイズが大きすぎます（4MB まで） |
| `UNSUPPORTED_MEDIA_TYPE`（415） | この形式の写真には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP） |
| `IMAGE_INVALID`（422） | この写真ではチケットを発行できません |
| `ANALYSIS_UPSTREAM_ERROR`（502）/ `ANALYSIS_TIMEOUT`（504） | ただいま混み合っています。時間をおいてお試しください |
| `BAD_REQUEST`（400） / その他 / 通信エラー | 発行できませんでした。もう一度お試しください |
| チケット画面の QR が読み込めない（B-2 の 403 など） | 無効なチケット URL です |

方式A・方式B とも、API はエラーを JSON で返す（B-1 は `Accept: application/json` のとき JSON）。

## 5. 状態管理（Pinia）

```ts
// src/stores/ticket.ts
export const useTicketStore = defineStore('ticket', () => {
  const file = ref<File | null>(null);
  const status = ref<'idle' | 'sending' | 'issued' | 'failed'>('idle');
  const inlineTicket = ref<InlineTicket | null>(null);   // 方式A の結果（発行画面に表示）
  const error = ref<string | null>(null);                // 画面に出すメッセージ（4.4）

  const fileProblem = computed(() => …);                  // 未選択・4MB 超・非対応の拡張子
  async function issueInline() { … }                      // 方式A
  async function issueForPage(): Promise<TicketRoute> { … } // 方式B: 成功したら { code, sig } を返し、画面がチケット画面へ移る
  function reset() { … }
  return { file, status, inlineTicket, error, fileProblem, issueInline, issueForPage, reset };
});
```

- 送信中は、どちらのボタンも押せないようにする（二重発行の防止）
- 方式B の結果はストアに持たない。チケット画面は URL だけから描画する
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
│   └── config.json         # ローカル開発用の既定値（配置時は環境ごとに差し替える）
└── src/
    ├── main.ts             # 設定を読み込み、Pinia と router を入れてマウント
    ├── App.vue             # <RouterView>
    ├── router.ts           # hash モード。#/ と #/tickets/:code
    ├── style.css           # @import "tailwindcss";
    ├── config.ts           # config.json の読み込みと検証（zod）
    ├── api/tickets.ts      # API クライアント、スキーマ（zod）、ApiError
    ├── stores/ticket.ts    # 発行の状態（Pinia）
    ├── pages/
    │   ├── IssuePage.vue       # 発行画面（写真の選択、方式A / B のボタン、方式A の結果）
    │   └── TicketPage.vue      # チケット画面（URL から描画。QR の読み込みエラーの表示）
    └── components/
        ├── PhotoPicker.vue     # ファイル選択と送信前の確認
        ├── TicketCard.vue      # QR・コード・発行日時の表示（方式A・B で共用）
        └── ErrorMessage.vue
```

## 7. 前提となる API 側の変更

| 変更 | 状態 | 内容 | 必要な理由 |
|---|---|---|---|
| B-1 の `Accept: application/json` 対応 | **実装済み**（Go・Node） | `201 { ticketCode, issuedAt, sig, qrUrl }`、エラーも JSON（DESIGN.md 5.2） | 方式B のため |
| CORS | 未実装（E2E.md 4.3） | A と B-1 のレスポンスに `Access-Control-Allow-Origin: {フロントのオリジン}` を付ける。本番は API Gateway HTTP API の CORS 設定、ローカルは各実装のローカルサーバー | 付けないと、SPA の JS が A・B-1 のレスポンスを読めない |
| Origin の照合 | 未実装（E2E.md 4.2） | A と B-1 で `Origin` を `ALLOWED_ORIGINS` と照合し、違えば 403 | 他のサイトから発行させないため（CSRF 対策） |
| 設定 | 未実装 | 環境変数 `ALLOWED_ORIGINS`、CloudFormation のパラメータ `AllowedOrigins` | フロントのオリジン（CloudFront のドメイン）を API に教える |

- `<img>` による QR の取得（B-2）には CORS は不要

## 8. 開発

```sh
cd docs/st/web
npm ci
npm run dev          # http://localhost:5173
```

- 開発時は Vite のプロキシで `/v1` をローカルの API（`http://localhost:8080`。Go 版 `make run` または Node 版 `npm run dev`）に転送し、`public/config.json` の `apiBaseUrl` を空（同じオリジン）にする。こうすると、7章の CORS が実装されるまでの間も、ローカルでは方式A・B の両方を確かめられる
- ただし API が返す `qrUrl` は API の `PUBLIC_BASE_URL`（`http://localhost:8080`）になる。チケット画面は `qrUrl()` で `apiBaseUrl` から組み立てるので、プロキシ経由で表示される
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
  img-src 'self' data: {apiBaseUrl}; connect-src {apiBaseUrl}; frame-ancestors 'none'
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
Strict-Transport-Security: max-age=31536000
```

- `img-src data:` は方式A の QR（data URL）、`img-src {apiBaseUrl}` は方式B の QR（B-2）のため
- `connect-src {apiBaseUrl}` は A・B-1 の `fetch` のため
- SPA からフォーム送信はしないので、`form-action` は不要

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
| API クライアント | `fetch` を差し替えて、201 / 各エラー / 予期しない応答 / 通信エラーの扱い、方式B で `Accept: application/json` を付けることを確かめる |
| ストア | 送信前の確認（未選択、4MB 超、拡張子）、二重送信の防止、エラーメッセージの対応 |
| チケット画面 | URL のパラメータの検証、`<img>` の読み込みエラー時の表示、コードからの発行日時の表示 |
| 通しの確認 | E2E.md の Playwright で、ビルドしたサイト + API（ローカル）を使って、スマートフォン相当の画面幅で方式A・B を操作する。方式B はチケット画面のリロードで再発行されないことも確かめる |

## 11. 決めておきたいこと

決定済み:

| 項目 | 決定 |
|---|---|
| チケット画面の描画 | SPA が描画する（方式B）。API の B-3（HTML の画面）は SPA では使わず、API 側に残す |
| 方式A | 残す（方式A・B の両方を出す。`config.json` で切り替え可能） |
| B-1 の返し方 | `Accept: application/json` で JSON に切り替える（API 側は実装済み） |

未確定:

1. 方式A の結果をリロード後も残すか（sessionStorage）。方式B があるので、既定では残さない案
2. 配置方式（推奨: CloudFront + 非公開 S3）と、独自ドメインを使うか
3. 7章の API 側の変更（CORS、Origin の照合）を、フロントエンドの実装より先に行ってよいか
4. 画面の文言・デザインの指定（今はシンプルな2画面を想定）
