# Node.js 実装 スタック案と実装方針

> **実装状況: 実装済み**（`node/`）。使い方は [9章](#9-使い方)、Go 版との突き合わせ結果は [10章](#10-go-版との突き合わせ結果)。

API の仕様は [DESIGN.md](DESIGN.md) を参照。Go 版（`go/`）と**同じ API 仕様・同じ共通テストデータ・同じテンプレート**で実装し、後で比較評価する。

## 1. 方針

| 方針 | 内容 |
|---|---|
| 言語 | **TypeScript**。ただし型を取り除くだけで JS になる構文に限定する（`erasableSyntaxOnly`）。人のレビューコストを見て、後から JS に切り替えられるようにするため（7章） |
| ファイル数 | **最小限にする**。Go 版はソース18ファイルに分かれているが、Node 版はソース4ファイルにまとめる |
| npm ライブラリ | 実行時の依存は **lean-qr だけ**。それ以外は Node 標準機能でまかなう。dev 依存（ビルド・型チェック・型定義）は、Lambda のパッケージに入らないので許容する |
| デプロイ単位 | Go 版と同じ2パッケージ: `ticketqr.zip`（チケット系4エンドポイント）、`exampleqr.zip`（example.com の QR） |
| Lambda 関数の分け方 | Go 版と同じ（CloudFormation テンプレートを共有し、`Impl=node` を指定するだけ）。`ticketqr.zip` を `tickets`（A / B-1 / B-3）と `get-qr`（B-2）の2関数で使う。どちらも同じ `handler`（`routeKey` で振り分け）をエクスポートする。関数の分け方が変わっても、Node のコードは変更しない |

## 2. スタック

| 項目 | 採用 | 備考 |
|---|---|---|
| ランタイム | Lambda **`nodejs24.x`**、arm64 | ES モジュール（`index.mjs`）、Handler は `index.handler` |
| 言語 | TypeScript 7 | `tsc --noEmit` で型チェックだけを行う（出力は esbuild が担当） |
| バンドル | esbuild | エントリポイントごとに1ファイルにまとめる。`@aws-sdk/*` はバンドルに含めない（Lambda ランタイムに同梱されているため） |
| ローカル実行・テスト | Node 標準の型除去（type stripping）で `.ts` を直接実行 | `tsx` や `ts-node` は不要 |
| テスト | `node:test` + `node:assert` | Jest や Vitest は不要 |
| QR 生成 | **lean-qr**（`lean-qr` + `lean-qr/extras/node_export`） | 3章 |

### 2.1 依存パッケージ

| 区分 | パッケージ | 用途 |
|---|---|---|
| dependencies | `lean-qr` 2.7.4 | QR 生成と PNG 出力 |
| devDependencies | `typescript` 7.0.2、`esbuild` 0.28.2、`@types/node`、`@types/aws-lambda` | 型チェック、バンドル、型定義（実行時には使わない） |
| devDependencies | `prettier` 3.9.9 | 整形（`printWidth` 120、シングルクォート）。設定は `.prettierrc.json` |
| devDependencies（型チェック用。バンドルしない） | `@aws-sdk/client-secrets-manager` | salt の取得。実行時は Lambda ランタイム同梱のものを `import()` で読む |

バージョンはすべて `package.json` で固定する（`--save-exact`）。

### 2.2 Node 標準機能で代替するもの（ライブラリを採用しない）

| 用途 | 使う標準機能 | 採用しなかったライブラリ |
|---|---|---|
| multipart/form-data の解析 | `new Request(url, { method, headers, body }).formData()`（undici 内蔵） | `busboy`（`streamsearch` に依存）、`formidable` |
| ヘッダーの取得（大文字小文字を区別しない） | `new Headers(event.headers).get(name)` | - |
| 署名（HMAC-SHA256 と base64url） | `crypto.createHmac(...).digest('base64url')`、`crypto.timingSafeEqual` | - |
| 乱数（suffix の生成） | `crypto.randomBytes` | `nanoid` など |
| リクエスト ID（ローカル実行時） | `crypto.randomUUID` | `uuid` |
| JST の日時の整形 | `Date` を +9時間ずらして `getUTC*` で取り出す | `dayjs`、`date-fns`（tzdata にも依存しない） |
| HTML の生成 | 共通テンプレートの `{{.Name}}` を、エスケープした値で置き換えるだけの小さな関数 | `handlebars`、`ejs` |
| ルーティング | `routeKey` での `switch` | `middy`、Lambda 向けの Web フレームワーク |
| ローカル HTTP サーバー | `node:http` | `express` |
| 環境変数ファイル | `node --env-file` | `dotenv` |

動作確認済み（Node 26）: `Request.formData()` で、Lambda と同じ形（ボディのバイト列 + `content-type` ヘッダー）の multipart を解析できる。`Headers` はヘッダー名の大文字小文字を区別しない。`createHmac().digest('base64url')` の先頭22文字が `testdata/signature.json` と一致する。

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
    ├── package.json           # scripts: dev / dev:example / test / typecheck / build
    ├── tsconfig.json
    ├── .prettierrc.json
    ├── src/
    │   ├── lib.ts             # 本体（下表）。import しただけでは副作用が起きない
    │   ├── ticketqr.ts        # Lambda エントリ: 初期化して handler = route をエクスポート
    │   ├── exampleqr.ts       # Lambda エントリ: example.com の QR
    │   └── local.ts           # ローカル HTTP サーバー（両パッケージを起動。開発専用でバンドルしない）
    └── test/
        └── lib.test.ts        # 単体テスト + ハンドラーのテスト（共通テストデータを使う）
```

### `lib.ts` の中身（セクションごとに区切った1ファイル）

レビューしやすいように、**全体像 → 詳細**の順に並べる。各セクションの見出しには、対応する Go のファイルを書く。関数名も Go と1対1で対応させる。

| # | セクション | 主な関数 | 対応する Go |
|---|---|---|---|
| 1 | 入口とルート表 | `ROUTES`（ルートキー → 関数名・エラー形式・処理）、`loadDeps`、`route`、`run` | `app`、`handler/route.go` |
| 2 | エンドポイント | `issueInline`（A）、`issue`（B-1）、`getView`（B-3）、`getQr`（B-2）、`verified`、`ticketUrl`、`exampleQr` | `handler/handler.go`、`exampleqr` |
| 3 | 発行処理 | `issueTicket`（画像チェック → 解析 → 採番） | `usecase/issue.go` |
| 4 | ドメインのルール（純粋関数。`../testdata` で検証する） | `generateTicket`、`newSigner`、`validateImage`、`newAnalyzer` / `alwaysValid`、`qrPng` | `ticketcode`、`signer`、`imageinput`、`analyzer`、`qr` |
| 5 | 入出力 | `loadConfig`、`loadSalts`、`loadViews`、`readFormImage`、各レスポンスの生成 | `config`、`secret`、`view`、`handler.go` の補助関数 |
| 6 | エラーとログ | `AppError` と各エラーの生成関数、`consoleLog` | `apperr`、slog |

- 関数はすべてモジュール直下に置き、依存部品は `deps` 引数で受け取る（入れ子のクロージャにしない）
- ルートの対応は `ROUTES` 表だけで定義する。`ROUTE_KEYS` はこの表から作り、ローカルサーバーもそれを使う。表のキーは文字列リテラルで書く。算出キー（`[CONST]`）にすると esbuild が表を削除できず、exampleqr のバンドルにチケット系のコードが入ってしまうため
- エントリポイントのファイル（`ticketqr.ts`、`exampleqr.ts`）は10行程度にする。初期化（設定と salt の取得、テンプレートの読み込み）は、`ticketqr.ts` のトップレベル `await` で、Lambda の初期化フェーズ中に1回だけ行う
- `exampleqr.ts` は `lib.ts` の qr と http 部分だけを使う。esbuild の tree shaking で、チケット系のコードはバンドルに含まれない

## 5. 実装方針の詳細

### 5.1 ハンドラー

```ts
export const route = (deps: Deps) => async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyStructuredResultV2> => {
  switch (event.routeKey) {
    case 'POST /v1/tickets/qr-inline': return run(event, 'issue-inline', jsonError, () => issueInline(deps, event));
    case 'POST /v1/tickets':           return run(event, 'issue', htmlError, () => issue(deps, event));
    // ...
    default:                           return run(event, 'unknown', jsonError, () => { throw notFound(); });
  }
};
```

- ルートキーは Go の `handler.RouteKeys` と同じ文字列
- `run` は Go と同じ役割（ログ出力と、`AppError` を各エンドポイントの形式のエラーに変換）。例外を Lambda に投げ返さない

### 5.2 multipart の読み取り

```ts
const body = event.isBase64Encoded ? Buffer.from(event.body ?? '', 'base64') : Buffer.from(event.body ?? '');
const form = await new Request('http://local/', { method: 'POST', headers: { 'content-type': ct }, body }).formData();
const file = form.get('image');   // File | string | null
```

- Content-Type が `multipart/form-data` でない、または boundary がない場合 → 415
- `formData()` が例外を投げた場合 → 400。`image` がない、または文字列だった場合 → 400
- `file.size > 4MB` → 413（Go と同じ判定順にする）
- パートの `Content-Type` は見ない。画像形式はマジックバイトで判定する

### 5.3 テンプレート

- Go の `html/template` と同じテンプレートファイルを使う。テンプレート中の構文は `{{.TicketCode}}` などの単純な埋め込みだけなので、`/\{\{\.(\w+)\}\}/g` で置き換える
- エスケープは Go の `html/template` と同じ出力にする: `&`→`&amp;`、`<`→`&lt;`、`>`→`&gt;`、`"`→`&#34;`、`'`→`&#39;`、`+`→`&#43;`、NUL→`U+FFFD`
- テンプレート読み込み時に `{{.Field}}` 以外の構文があればエラーにする（Go と共有できないテンプレートを早期に検出する）
- テンプレートの場所: `TEMPLATES_DIR`（既定値はバンドルと同じ階層の `templates/`）から、初期化時に `fs.readFileSync` で読む。ビルド時に `../templates/*.html` を zip にコピーする。ローカル実行（`local.ts`）は既定値として `../templates` を設定し、テストはファイルのパスを直接渡す
- テンプレートに `{{if}}` などの制御構文を使い始めたら、この方式は見直す（Go と Node で同じテンプレートを共有する前提が崩れるため）

### 5.4 salt の取得

- `@aws-sdk/client-secrets-manager` はランタイム同梱のものを使う（esbuild では `--external:@aws-sdk/*`）
- Go と同じく、`APP_ENV=local` のときに限り `SIGNING_SALT` の平文を使う

### 5.5 ログ

- `console.log(JSON.stringify({ level, msg, requestId, endpoint, status, durationMs, ... }))` で、Go の slog（JSON）と同じキーにそろえる
- 画像データと `sig` はログに出さない

## 6. ビルド・実行・テスト

| npm スクリプト | 内容 |
|---|---|
| `npm run dev` | `node src/local.ts`。`:8080`（チケット系 + アップロードフォーム）と `:8081`（example）を起動する。`APP_ENV=local` などのローカル用の値は `local.ts` が既定値として設定する（Go の `make run` / `make run-example` と同じ URL 構成） |
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
    "allowImportingTsExtensions": true,  // 型除去で直接実行するため、import は './lib.ts' と書く
    "verbatimModuleSyntax": true
  }
}
```

- zip の名前は Go 版と同じ（`ticketqr.zip`、`exampleqr.zip`）。CloudFormation の `Impl=node` では、`ImplMap` の Runtime（`nodejs24.x`）と Handler（`index.handler`）だけが変わる
- 実測サイズ（10章）: `ticketqr.zip` 9.0KB、`exampleqr.zip` 4.8KB（Go 版は 4.9MB、2.9MB）。コールドスタートの比較ポイントになる

### テスト方針

| 対象 | 方法 |
|---|---|
| 採番・署名 | `testdata/ticketcode.json`、`testdata/signature.json` を Go と同じテストデータとして使う |
| ハンドラー | Go の `handler_test.go` と同じケース（正常系、各エラー、PRG の流れ、署名の必須チェック、HTML のエスケープ、ルーティング） |
| QR | Node の単体テストでは、PNG のシグネチャと、IHDR のサイズが「256px 以内に収まる最大の整数倍」になっていることを確認する |
| QR の読み取り（両実装） | 契約テスト（`tests/contract`）で、Go と Node の両方のサーバーに同じリクエストを送り、返ってきた PNG を Go の gozxing で読み取って比べる。Node 側に QR デコーダーの dev 依存は追加しない |
| HTML の一致 | 契約テストで、同じ `ticketCode` と `sig` を指定したときの B-3 の HTML を比べる |

## 7. 後で JS に切り替える場合

`erasableSyntaxOnly` によって、TS 固有の構文は型注釈だけに限定してある。そのため、次の手順で切り替えられる。

1. 型注釈を取り除く（`esbuild --format=esm` をファイル単位でかけるか、手作業で消す）。必要なら JSDoc の型コメントと `// @ts-check` に置き換えて、`tsc --noEmit` による型チェックを残す
2. `import './lib.ts'` を `'./lib.js'` に変える
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
npm test             # 43件。共通テストデータ（../testdata）と Go と同じハンドラーのケース
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

同じ設定（salt、`PUBLIC_BASE_URL`）で Go と Node のローカルサーバーを起動し、同じリクエストを送って比べた。

| 対象 | 結果 |
|---|---|
| B-3 のビュー HTML（同じ `ticketCode` と `sig`） | バイト単位で一致 |
| B-3 の 403 エラー HTML、B-2 の 403 エラー JSON、A の 415 エラー JSON | バイト単位で一致 |
| B-3 のレスポンスヘッダー | 一致（ローカルサーバーが付ける `Transfer-Encoding` 以外） |
| B-2 の QR PNG | Go は 256×256、Node は 232×232（許容済み）。どちらも Go の gozxing で読み取ると同じチケットコードになる |
| Lambda での動作 | `public.ecr.aws/lambda/nodejs:24`（Lambda のエミュレーター入り）で `dist/*.zip` を動かし、A（201）、B-1（303）、署名不一致（403）、example（200 PNG）を確認 |
| zip サイズ | ticketqr 9.0KB / exampleqr 4.8KB（Go: 4.9MB / 2.9MB） |

