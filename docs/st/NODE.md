# Node.js 実装 スタック案と実装方針

> **実装状況: 実装済み**（`node/`）。使い方は [9章](#9-使い方)、Go 版との突き合わせ結果は [10章](#10-go-版との突き合わせ結果)。

API の仕様は [DESIGN.md](DESIGN.md) を参照。Go 版（`go/`）と**同じ API 仕様・同じ共通テストデータ・同じテンプレート**で実装し、後で比較評価する。

## 1. 方針

| 方針 | 内容 |
|---|---|
| 言語 | **TypeScript**。ただし型を取り除くだけで JS になる構文に限定する（`erasableSyntaxOnly`）。人のレビューコストを見て、後から JS に切り替えられるようにするため（7章） |
| ファイル数 | **少なく保つ**。Go 版はソース18ファイルに分かれているが、Node 版は層ごとに分けたソース3ファイル（`domain.ts` / `infra.ts` / `app.ts`）と入口ファイルにまとめる |
| npm ライブラリ | 実行時の依存は **依存ゼロの薄いパッケージだけ**: lean-qr（QR）、hono + @hono/aws-lambda（ルーティングと Lambda イベント変換）。それ以外は Node 標準機能でまかなう。dev 依存は Lambda のパッケージに入らないので許容する |
| デプロイ単位 | Go 版と同じ2パッケージ: `ticketqr.zip`（チケット系4エンドポイント）、`exampleqr.zip`（example.com の QR） |
| Lambda 関数の分け方 | Go 版と同じ（CloudFormation テンプレートを共有し、`Impl=node` を指定するだけ）。`ticketqr.zip` を `tickets`（A / B-1 / B-3）と `get-qr`（B-2）の2関数で使う。どちらも同じ `handler`（Hono アプリがパスで振り分け）をエクスポートする。関数の分け方が変わっても、Node のコードは変更しない |

## 2. スタック

| 項目 | 採用 | 備考 |
|---|---|---|
| ランタイム | Lambda **`nodejs24.x`**、arm64 | ES モジュール（`index.mjs`）、Handler は `index.handler` |
| 言語 | TypeScript 7 | `tsc --noEmit` で型チェックだけを行う（出力は esbuild が担当） |
| バンドル | esbuild | エントリポイントごとに1ファイルにまとめる。`@aws-sdk/*` はバンドルに含めない（Lambda ランタイムに同梱されているため） |
| ローカル実行・テスト | Node 標準の型除去（type stripping）で `.ts` を直接実行 | `tsx` や `ts-node` は不要 |
| テスト | `node:test` + `node:assert` | Jest や Vitest は不要 |
| QR 生成 | **lean-qr**（`lean-qr` + `lean-qr/extras/node_export`） | 3章 |
| HTTP / Lambda | **Hono** 4.13 + **@hono/aws-lambda** 1.0 | ルーティング、リクエスト / レスポンス、API Gateway v2 イベントとの変換（バイナリの base64 化を含む）。ローカルは `@hono/node-server` で同じアプリを起動する。`hono/aws-lambda` は v5 で削除予定のため、独立パッケージ `@hono/aws-lambda` を使う |

### 2.1 依存パッケージ

| 区分 | パッケージ | 用途 |
|---|---|---|
| dependencies | `lean-qr` 2.7.4 | QR 生成と PNG 出力 |
| dependencies | `hono` 4.13.13、`@hono/aws-lambda` 1.0.0 | ルーティングと Lambda イベント変換（どちらも依存なし） |
| devDependencies | `@hono/node-server` 2.1.3 | ローカルサーバー |
| devDependencies | `typescript` 7.0.2、`esbuild` 0.28.2、`@types/node`、`@types/aws-lambda` | 型チェック、バンドル、型定義（実行時には使わない） |
| devDependencies | `prettier` 3.9.9 | 整形（`printWidth` 120、シングルクォート）。設定は `.prettierrc.json` |
| devDependencies（型チェック用。バンドルしない） | `@aws-sdk/client-secrets-manager` | salt の取得。実行時は Lambda ランタイム同梱のものを `import()` で読む |

バージョンはすべて `package.json` で固定する（`--save-exact`）。

### 2.2 ライブラリの採否

| 用途 | 使う標準機能 | 採用しなかったライブラリ |
|---|---|---|
| multipart/form-data の解析 | Hono の `c.req.formData()`（中身は標準の `Request.formData()`） | `busboy`（`streamsearch` に依存）、`formidable` |
| Content-Type の確認 | `multipart/form-data` で始まるかを正規表現で1行確認する（boundary などの細部は `formData()` に任せる） | `content-type`（一度入れたが、Go と細部の挙動を合わせるためだけだったので外した） |
| ヘッダーの取得 | Hono の `c.req.header()` | - |
| 署名（HMAC-SHA256 と base64url） | `crypto.createHmac(...).digest('base64url')`、`crypto.timingSafeEqual` | - |
| 乱数（suffix の生成） | `crypto.randomBytes` | `nanoid` など |
| リクエスト ID（ローカル実行時） | `crypto.randomUUID` | `uuid` |
| JST の日時の整形 | `Date` を +9時間ずらして `getUTC*` で取り出す | `dayjs`、`date-fns`（tzdata にも依存しない） |
| HTML の生成とエスケープ | 共通テンプレートの `{{.Name}}` を、`& < > " '` を数値文字参照（`&#NN;`）にした値で置き換える小さな関数 | `handlebars`、`ejs`、`escape-html` / `hono/html`（`"` を `&quot;` にするので Go 版と HTML が一致しない） |
| ルーティング | **Hono**（ルート表から `app.on()` で登録） | `middy`（複数パッケージ、エラー形式は結局自作） |
| ローカル HTTP サーバー | **@hono/node-server**（Lambda と同じ Hono アプリを起動） | `express` |
| 設定値の検証 | 手書き（約20行） | `valibot`（画像解析の本物のクライアントでレスポンス検証が必要になった時点で、設定・salt とあわせて再検討する） |
| 環境変数ファイル | `node --env-file` | `dotenv` |

Hono の `c.req.formData()` は `application/x-www-form-urlencoded` も受け付けるので、Content-Type が `multipart/form-data` で始まるかだけは先に確かめて 415 を返す（仕様上の要件）。それ以外の形式の崩れ（boundary なし、壊れたボディ、`image` がファイルでない）はまとめて 400 にする。

## 3. QR 生成: lean-qr

| 項目 | 内容 |
|---|---|
| バージョン | 2.7.4（MIT） |
| 依存 | **なし** |
| サイズ | 本体 `index.mjs` が 6.9KB、PNG 出力の `extras/node_export.mjs` が 1.1KB（`node:zlib` だけを使う）。バンドルに含まれるのはこの2つだけ |
| 比較: `qrcode`（npm） | `pngjs`、`yargs`、`dijkstrajs` に依存。CLI 用の依存まで入るので採用しない |

```ts
import { generate, correction } from 'lean-qr';
import { toPngBuffer } from 'lean-qr/extras/node_export';

const code = generate(text, { minCorrectionLevel: correction.M, maxCorrectionLevel: correction.M });
const scale = Math.floor(256 / (code.size + 8));               // 256px 以内に収まる最大の整数倍
const png = toPngBuffer(code, { on: [0, 0, 0], off: [255, 255, 255], pad: 4, scale });
```

確認済み: `20261002141453-A5T1DT4M` から作った PNG を Go 側のデコーダー（gozxing）で読み取ると、元の文字列に戻る。

### Go 版との違い（仕様として許容することで決定）

| 項目 | Go（skip2/go-qrcode） | Node（lean-qr） |
|---|---|---|
| 画像サイズ | 256×256 固定 | `(モジュール数 + 8) × scale`。scale は 256 以下に収まる最大の整数（チケットコードの場合は 21モジュール × 8 = **232×232**） |
| 誤り訂正レベル | M | M（`min` と `max` の両方を M に固定。lean-qr は余裕があると勝手に上げるため） |
| 余白 | 4モジュール | 4モジュール（`pad: 4`） |
| 背景 | 白 | 白。**`off` を明示的に指定する**（既定値は透明） |
| PNG の形式 | 1bit のパレット形式 | 1bit のパレット形式 |

- 両実装の一致は「QR を読み取った結果が同じであること」で確認する（画像のバイト一致は求めない。DESIGN.md 11章と同じ）
- HTML は `<img width="256" height="256">` で表示するので、232px でも表示上の大きさは変わらない
- 画像サイズの違い（Go 256px / Node 232px）は**許容することで決定済み**
- 256px ちょうどにしたい場合は、余白のピクセル数を自分で計算して画像を組み立てる必要がある。Go の yeqown 版で同じことをして複雑になったため、採用しない

## 4. ファイル構成

```
st/
├── templates/                 # Go と共有（ticket.html / error.html）
├── testdata/                  # Go と共有（ticketcode.json / signature.json）
└── node/
    ├── package.json           # scripts: dev / test / typecheck / format / build
    ├── tsconfig.json
    ├── .prettierrc.json
    ├── src/
    │   ├── domain.ts          # ビジネスロジック（外部入出力なし。node:crypto だけ使う）
    │   ├── infra.ts           # 外部とのやり取りの実装（環境変数・Secrets Manager・テンプレート・lean-qr・解析クライアント・ログ）
    │   ├── app.ts             # HTTP 層（Hono）: ルート表・エンドポイント・リクエスト / レスポンス、依存の組み立て
    │   ├── ticketqr.ts        # Lambda エントリ: handler = handle(createApp(await loadDeps()))
    │   ├── exampleqr.ts       # Lambda エントリ: handler = handle(createExampleApp())
    │   └── local.ts           # ローカルサーバー（@hono/node-server で同じアプリを起動。開発専用でバンドルしない）
    └── test/
        └── app.test.ts        # 単体テスト + ハンドラーのテスト（共通テストデータを使う）
```

### 層の分け方

クリーンアーキテクチャに近い考え方で、**ビジネスロジック**と、**外部とのやり取りの実装**（環境変数、AWS、ファイル、ライブラリ）をファイルで分ける。各セクションの見出しには対応する Go のファイルを書き、関数名も Go と1対1で対応させる。

```
app.ts ──▶ domain.ts ◀── infra.ts
   └──────────────────────▶ infra.ts
（domain.ts はどこにも依存しない。infra.ts は domain.ts の型だけを参照する）
```

| ファイル | 層 | 主な関数・型 | 対応する Go |
|---|---|---|---|
| `domain.ts` | ビジネスロジック | `issueTicket`（画像チェック → 解析 → 採番）、`generateTicket`、`newSigner`、`validateImage`、外部とのインターフェース（`Analyzer`、`Log`、`AnalyzerError`）、`AppError` と各エラー | `usecase`、`ticketcode`、`signer`、`imageinput`、`analyzer`（型）、`apperr` |
| `infra.ts` | 外部とのやり取りの実装 | `loadConfig`、`loadSalts`（Secrets Manager）、`newAnalyzer` / `alwaysValid`（解析クライアント。今はモック）、`qrPng`（lean-qr）、`loadViews`（テンプレート）、`consoleLog` | `config`、`secret`、`analyzer`（実装）、`qr`、`view`、slog |
| `app.ts` | HTTP 層と組み立て | `ROUTES`、`createApp`、`run`、各エンドポイント（`issueInline` / `issue` / `getView` / `getQr`）、`verified`、`ticketUrl`、`createExampleApp`、`readFormImage`、レスポンスの生成、`loadDeps` | `app`、`handler`、`exampleqr` |

- `domain.ts` は外部と直接やり取りしない。画像解析とログは、`issueTicket` が受け取る `IssuePorts`（`analyzer`、`newTicket`、`log`）を通して使う。テストでは、ここに差し替え用の実装（スタブ）を渡す
- 関数はすべてモジュール直下に置き、依存部品は引数（`deps` と Hono の `c`）で受け取る
- ルートは `app.ts` の `ROUTES` 表だけで定義し、`createApp` が表から Hono に登録する。`ROUTE_KEYS`（API Gateway の表記）は表から作り、Go の `RouteKeys` との一致をテストで確認する。`ROUTE_KEYS` は `/* @__PURE__ */` を付けて、使わないバンドル（exampleqr）で表ごと削除されるようにする
- Go は `routeKey` で振り分けるが、Node（Hono）はパスで振り分ける。API Gateway で一致したルートのパスがそのまま届くので、結果は同じ
- エントリポイントのファイル（`ticketqr.ts`、`exampleqr.ts`）は10行程度にする。初期化（設定と salt の取得、テンプレートの読み込み）は、`ticketqr.ts` のトップレベル `await` で、Lambda の初期化フェーズ中に1回だけ行う
- `exampleqr.ts` は `app.ts` の `createExampleApp` と `infra.ts` の `qrPng` だけを使う。esbuild の tree shaking で、チケット系のコードはバンドルに含まれない

## 5. 実装方針の詳細

### 5.1 ルーティング（Hono）

```ts
// prettier-ignore
const ROUTES = [
  // method  path                            log name        errors  handler
  ['POST',   '/v1/tickets/qr-inline',        'issue-inline', 'json', issueInline],
  ['POST',   '/v1/tickets',                  'issue',        'html', issue],
  ['GET',    '/v1/tickets/:ticketCode/view', 'get-view',     'html', getView],
  ['GET',    '/v1/tickets/:ticketCode/qr',   'get-qr',       'json', getQr],
];

export function createApp(deps) {
  const app = new Hono();
  for (const [method, path, name, errors, endpoint] of ROUTES) app.on(method, path, (c) => run(c, deps, name, errors, () => endpoint(c, deps)));
  app.notFound((c) => run(c, deps, 'unknown', 'json', async () => { throw notFound(); }));
  return app;
}
```

- `run` は Go と同じ役割（ログ出力と、`AppError` を各エンドポイントの形式のエラーに変換）。例外を Hono や Lambda に投げ返さない
- レスポンスは `c.json()` / `c.html()` ではなく `c.body(…, status, headers)` でヘッダーを明示する。`c.html()` は `charset=UTF-8`（大文字）を付けるなど、Go 版とヘッダーが一致しなくなるため
- PNG は `Content-Type: image/png` で返すだけで、`@hono/aws-lambda` が base64 にして `isBase64Encoded: true` を付ける

### 5.2 multipart の読み取り

```ts
if (!/^multipart\/form-data\b/i.test(c.req.header('content-type') ?? '')) throw unsupportedMediaType(...); // 415
const image = await c.req.formData().then((form) => form.get('image'), () => null);
if (!(image instanceof File)) throw badRequest('image file is required');                               // 400
```

- 要件として守るのは「multipart 以外は 415」「`image` ファイルを受け取る」の2点だけ。boundary がない、ボディが壊れている、`image` がない、`image` がファイルでない（文字列）は、まとめて 400 にする
- サイズ（4MB 超 → 413）と形式（マジックバイト）は `validateImage` で判定する（Go と同じ順番）
- パートの `Content-Type` は見ない

### 5.3 テンプレート

- Go の `html/template` と同じテンプレートファイルを使う。テンプレート中の構文は `{{.TicketCode}}` などの単純な埋め込みだけなので、`/\{\{\.(\w+)\}\}/g` で置き換える
- エスケープは `& < > " '` を数値文字参照（`&#38;` など）にする1行の関数。XSS を防ぐという要件だけを満たす
- Go の `html/template` とは書き方が違う（Go は `&amp;`、`&#34;` など。`+` と NUL も置き換える）。違いが出るのは記号を含む値（不正なチケットコードなど）を表示するときだけで、通常のチケットコード・URL・エラーメッセージの HTML は Go と一致する
- テンプレート読み込み時に `{{.Field}}` 以外の構文があればエラーにする（Go と共有できないテンプレートを早期に検出する）
- テンプレートの場所: `TEMPLATES_DIR`（既定値はバンドルと同じ階層の `templates/`）から、初期化時に `fs.readFileSync` で読む。ビルド時に `../templates/*.html` を zip にコピーする。ローカル実行（`local.ts`）は既定値として `../templates` を設定し、テストはファイルのパスを直接渡す
- テンプレートに `{{if}}` などの制御構文を使い始めたら、この方式は見直す（Go と Node で同じテンプレートを共有する前提が崩れるため）

### 5.4 salt の取得

- `@aws-sdk/client-secrets-manager` はランタイム同梱のものを使う（esbuild では `--external:@aws-sdk/*`）
- Go と同じく、`APP_ENV=local` のときに限り `SIGNING_SALT` の平文を使う

### 5.5 ログ

- `console.log(JSON.stringify({ time, level, msg, requestId, endpoint, status, durationMs, ... }))` で、Go の slog（JSON）と同じキーにそろえる。`requestId` は Lambda では API Gateway のリクエスト ID（Hono の `c.env.requestContext`）、ローカルでは `randomUUID()`
- 画像データと `sig` はログに出さない

## 6. ビルド・実行・テスト

| npm スクリプト | 内容 |
|---|---|
| `npm run dev` | `node src/local.ts`。`@hono/node-server` で `:8080`（チケット系 + アップロードフォーム）と `:8081`（example）を起動する。`APP_ENV=local` などのローカル用の値は `local.ts` が既定値として設定する（Go の `make run` / `make run-example` と同じ URL 構成） |
| `npm test` | `node --test 'test/*.test.ts'` |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run format` / `format:check` | prettier で `src` と `test` を整形する / 整形済みか確認する（CI では `format:check`）。縦にそろえた表（`ROUTES`、`HTML_ESCAPES`）は `// prettier-ignore` で整形の対象から外す |
| `npm run build` | esbuild で `dist/ticketqr/index.mjs`（`@aws-sdk/*` は外部扱い）と `dist/exampleqr/index.mjs` を作り、`dist/ticketqr.zip`（`index.mjs` + `templates/*.html`）と `dist/exampleqr.zip` にまとめる |

```jsonc
// tsconfig.json（概要）
{
  "compilerOptions": {
    "target": "es2023", "module": "nodenext", "strict": true, "noEmit": true,
    "erasableSyntaxOnly": true,          // enum、namespace、引数プロパティを禁止（型を消すだけで JS になるように）
    "allowImportingTsExtensions": true,  // 型除去で直接実行するため、import は './domain.ts' のように拡張子付きで書く
    "verbatimModuleSyntax": true
  }
}
```

- zip の名前は Go 版と同じ（`ticketqr.zip`、`exampleqr.zip`）。CloudFormation の `Impl=node` では、`ImplMap` の Runtime（`nodejs24.x`）と Handler（`index.handler`）だけが変わる
- 実測サイズ（10章）: `ticketqr.zip` 17KB、`exampleqr.zip` 14KB（Hono 導入前は 9.0KB / 4.8KB。Go 版は 4.9MB / 2.9MB）。コールドスタートの比較ポイントになる

### テスト方針

| 対象 | 方法 |
|---|---|
| 採番・署名 | `testdata/ticketcode.json`、`testdata/signature.json` を Go と同じテストデータとして使う |
| ハンドラー | Go の `handler_test.go` と同じケース（正常系、各エラー、PRG の流れ、署名の必須チェック、HTML のエスケープ、ルーティング）。API Gateway v2 のイベントを `@hono/aws-lambda` の `handle()` に渡して確認するので、Lambda イベントとの変換もテストの対象になる |
| QR | Node の単体テストでは、PNG のシグネチャと、IHDR のサイズが「256px 以内に収まる最大の整数倍」になっていることを確認する |
| QR の読み取り（両実装） | 契約テスト（`tests/contract`）で、Go と Node の両方のサーバーに同じリクエストを送り、返ってきた PNG を Go の gozxing で読み取って比べる。Node 側に QR デコーダーの dev 依存は追加しない |
| HTML の一致 | 契約テストで、同じ `ticketCode` と `sig` を指定したときの B-3 の HTML を比べる |

## 7. 後で JS に切り替える場合

`erasableSyntaxOnly` によって、TS 固有の構文は型注釈だけに限定してある。そのため、次の手順で切り替えられる。

1. 型注釈を取り除く（`esbuild --format=esm` をファイル単位でかけるか、手作業で消す）。必要なら JSDoc の型コメントと `// @ts-check` に置き換えて、`tsc --noEmit` による型チェックを残す
2. import の拡張子を `.ts` から `.js` に変える
3. ビルド（esbuild）、テスト、ローカル実行の手順は変わらない

判断材料: TS のままなら、型チェックでレビューの負担が減る。JS にすれば、ビルドなしでそのまま読めるコードになる。ファイル数が少ないので、どちらにしても切り替えのコストは小さい。

## 8. 未確定・確認事項

決定済み:

| 項目 | 決定 |
|---|---|
| Lambda ランタイム | `nodejs24.x` |
| QR 画像サイズの Go との違い（256px / 232px） | 許容する |
| TS か JS か | 当面は TS。JS にするかは別途検討する（本ドキュメントでは扱わない） |

未確定: なし

## 9. 使い方

```sh
cd docs/st/node
npm ci
npm run dev          # http://localhost:8080/（フォーム）、http://localhost:8081/v1/example/qr
npm test             # 45件。共通テストデータ（../testdata）と Go と同じハンドラーのケース
npm run typecheck
npm run format:check
npm run build        # dist/ticketqr.zip、dist/exampleqr.zip
```

| 環境変数 | 内容 |
|---|---|
| `PUBLIC_BASE_URL`、`ANALYZER_MODE`、`SIGNING_SALT_SECRET_ID`、`TICKET_SUFFIX_LENGTH`、`APP_ENV` / `SIGNING_SALT` | Go 版と同じ（`go/README.md`） |
| `TEMPLATES_DIR` | テンプレートの場所。既定値はバンドルと同じ階層の `templates/` |
| `PORT` / `EXAMPLE_PORT` | `npm run dev` の待ち受けポート（既定値 8080 / 8081） |

デプロイは `DEPLOY.md` を参照（`Impl=node` を指定し、`node/dist/*.zip` をアップロードする）。

## 10. Go 版との突き合わせ結果

同じ設定（salt、`PUBLIC_BASE_URL`）で Go と Node のローカルサーバーを起動し、同じリクエストを送って比べた（Hono 導入後に再確認）。

| 対象 | 結果 |
|---|---|
| B-3 のビュー HTML（同じ `ticketCode` と `sig`） | バイト単位で一致 |
| 403 エラー（B-3 の HTML、B-2 の JSON）、415 エラー（A の JSON、B-1 の HTML、urlencoded） | バイト単位で一致 |
| レスポンスヘッダー（B-3、B-3 の 403、B-2 の 403、B-2 の PNG） | 一致（ヘッダー名の大文字小文字と、サーバーが付ける `Date`・`Content-Length` などを除く） |
| B-1 の 303 | `Location` の形が一致（`{PUBLIC_BASE_URL}/v1/tickets/{code}/view?sig=…`） |
| B-2 の QR PNG | Go は 256×256、Node は 232×232（許容済み）。どちらも Go の gozxing で読み取ると同じチケットコードになる |
| Lambda での動作 | `public.ecr.aws/lambda/nodejs:24`（Lambda のエミュレーター入り）で `dist/*.zip` に API Gateway v2 のイベントを送り、A（201）、B-1（303）、B-3（200 HTML）、B-2（200 PNG、base64）、署名不一致（403）、未定義のルート（404 JSON）、example（200 PNG）を確認 |
| zip サイズ | ticketqr 17KB / exampleqr 14KB（Go: 4.9MB / 2.9MB） |

既知の差（いずれも要件外の細部。Node はビジネス要件だけを満たす簡略な実装にしているため）:

| ケース | Go | Node |
|---|---|---|
| `multipart/form-data` だが boundary がない | 415 `UNSUPPORTED_MEDIA_TYPE` | 400 `BAD_REQUEST` |
| 壊れた multipart、`image` がない | 400 `BAD_REQUEST` / `image is required` など | 400 `BAD_REQUEST` / `image file is required` |
| `image` がファイルではなく文字列で送られた | その文字列を画像として扱い、形式判定で 415 | 400 `BAD_REQUEST` |
| 記号（`& < > " '` など）を含む値の HTML エスケープ | `&amp;`、`&#34;` など（`+`、NUL も置き換える） | `&#38;`、`&#34;` などの数値文字参照 |
| パスのチケットコードが空（`/v1/tickets//view`） | ハンドラーを直接呼ぶと 403 | ルートに一致しないので 404。API Gateway 経由では Go も同じ（ルートに一致しない） |
