# Node.js 実装 スタック案と実装方針

API の仕様は [DESIGN.md](DESIGN.md) を参照。Go 版（`go/`）と**同じ API 仕様・同じ共通テストデータ・同じテンプレート**で実装し、後で比較評価する。

## 1. 方針

| 方針 | 内容 |
|---|---|
| 言語 | **TypeScript**。ただし型を取り除くだけで JS になる構文に限定する（`erasableSyntaxOnly`）。人のレビューコストを見て、後から JS に切り替えられるようにするため（7章） |
| ファイル数 | **最小限にする**。Go 版はソース18ファイルに分かれているが、Node 版はソース4ファイルにまとめる |
| npm ライブラリ | 実行時の依存は **lean-qr だけ**。それ以外は Node 標準機能でまかなう。dev 依存（ビルド・型チェック・型定義）は、Lambda のパッケージに入らないので許容する |
| デプロイ単位 | Go 版と同じ2パッケージ: `ticketqr.zip`（チケット系4エンドポイント）、`exampleqr.zip`（example.com の QR） |

## 2. スタック

| 項目 | 採用 | 備考 |
|---|---|---|
| ランタイム | Lambda `nodejs24.x`（使えないリージョンでは `nodejs22.x`）、arm64 | ES モジュール（`index.mjs`）、Handler は `index.handler` |
| 言語 | TypeScript 7 | `tsc --noEmit` で型チェックだけを行う（出力は esbuild が担当） |
| バンドル | esbuild | エントリポイントごとに1ファイルにまとめる。`@aws-sdk/*` はバンドルに含めない（Lambda ランタイムに同梱されているため） |
| ローカル実行・テスト | Node 標準の型除去（type stripping）で `.ts` を直接実行 | `tsx` や `ts-node` は不要 |
| テスト | `node:test` + `node:assert` | Jest や Vitest は不要 |
| QR 生成 | **lean-qr**（`lean-qr` + `lean-qr/extras/node_export`） | 3章 |

### 2.1 依存パッケージ

| 区分 | パッケージ | 用途 |
|---|---|---|
| dependencies | `lean-qr` | QR 生成と PNG 出力 |
| devDependencies | `typescript`、`esbuild`、`@types/node`、`@types/aws-lambda` | 型チェック、バンドル、型定義（実行時には使わない） |
| ランタイム同梱（バンドルしない） | `@aws-sdk/client-secrets-manager` | salt の取得 |

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

### Go 版との違い（仕様として許容する）

| 項目 | Go（skip2/go-qrcode） | Node（lean-qr） |
|---|---|---|
| 画像サイズ | 256×256 固定 | `(モジュール数 + 8) × scale`。scale は 256 以下に収まる最大の整数（チケットコードの場合は 21モジュール × 8 = **232×232**） |
| 誤り訂正レベル | M | M（`min` と `max` の両方を M に固定。lean-qr は余裕があると勝手に上げるため） |
| 余白 | 4モジュール | 4モジュール（`pad: 4`） |
| 背景 | 白 | 白。**`off` を明示的に指定する**（既定値は透明） |
| PNG の形式 | 1bit のパレット形式 | 1bit のパレット形式 |

- 両実装の一致は「QR を読み取った結果が同じであること」で確認する（画像のバイト一致は求めない。DESIGN.md 11章と同じ）
- HTML は `<img width="256" height="256">` で表示するので、232px でも表示上の大きさは変わらない
- 256px ちょうどにしたい場合は、余白のピクセル数を自分で計算して画像を組み立てる必要がある。Go の yeqown 版で同じことをして複雑になったため、採用しない

## 4. ファイル構成

```
st/
├── templates/                 # Go と共有（ticket.html / error.html）
├── testdata/                  # Go と共有（ticketcode.json / signature.json）
└── node/
    ├── package.json           # scripts: dev / dev:example / test / typecheck / build
    ├── tsconfig.json
    ├── src/
    │   ├── lib.ts             # 本体（下表）。import しただけでは副作用が起きない
    │   ├── ticketqr.ts        # Lambda エントリ: 初期化して handler = route をエクスポート
    │   ├── exampleqr.ts       # Lambda エントリ: example.com の QR
    │   └── local.ts           # ローカル HTTP サーバー（両パッケージを起動。開発専用でバンドルしない）
    └── test/
        └── lib.test.ts        # 単体テスト + ハンドラーのテスト（共通テストデータを使う）
```

### `lib.ts` の中身（セクションごとに区切った1ファイル）

| セクション | 内容 | 対応する Go パッケージ |
|---|---|---|
| config | 環境変数（`PUBLIC_BASE_URL`、`ANALYZER_MODE`、`TICKET_SUFFIX_LENGTH`、`SIGNING_SALT_SECRET_ID`） | `config`、`secret` |
| errors | `AppError`（status、code、message）と各エラーの生成関数 | `apperr` |
| ticketCode | `{YYYYMMDDHHmmss}-{suffix}` の生成。時刻と乱数源は引数で差し替えられるようにする | `ticketcode` |
| signer | `sign` / `verify`（現行と旧の salt） | `signer` |
| image | マジックバイトでの判定、4MB の上限 | `imageinput` |
| analyzer | `Analyzer` 型と常に valid を返すモック。送信形式は `application/octet-stream`（DESIGN.md 7章） | `analyzer` |
| qr | `qrPng(text)` | `qr` |
| view | テンプレートの読み込みと値の埋め込み | `view` |
| http | `readFormImage`、JSON / HTML / PNG のレスポンス、共通ヘッダー | `handler`（一部） |
| handlers | `issueInline` / `issue` / `getView` / `getQr` / `route` / `exampleQr` | `handler`、`usecase`、`exampleqr` |

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
- エスケープは Go の `html/template` と同じ出力にする: `&`→`&amp;`、`<`→`&lt;`、`>`→`&gt;`、`"`→`&#34;`、`'`→`&#39;`
- テンプレートの場所: `TEMPLATES_DIR`（既定値はバンドルと同じ階層の `templates/`）から、初期化時に `fs.readFileSync` で読む。ビルド時に `../templates/*.html` を zip にコピーする。ローカル実行とテストでは、npm スクリプトで `TEMPLATES_DIR=../templates` を指定する
- テンプレートに `{{if}}` などの制御構文を使い始めたら、この方式は見直す（Go と Node で同じテンプレートを共有する前提が崩れるため）

### 5.4 salt の取得

- `@aws-sdk/client-secrets-manager` はランタイム同梱のものを使う（esbuild では `--external:@aws-sdk/*`）
- Go と同じく、`APP_ENV=local` のときに限り `SIGNING_SALT` の平文を使う

### 5.5 ログ

- `console.log(JSON.stringify({ level, msg, requestId, endpoint, status, durationMs, ... }))` で、Go の slog（JSON）と同じキーにそろえる
- 画像データと `sig` はログに出さない

## 6. ビルド・実行・テスト

```jsonc
// package.json の scripts（概要）
{
  "dev":         "APP_ENV=local SIGNING_SALT=local-dev-salt ANALYZER_MODE=mock TEMPLATES_DIR=../templates node src/local.ts",
  "test":        "TEMPLATES_DIR=../templates node --test test/",
  "typecheck":   "tsc --noEmit",
  "build":       "npm run build:ticketqr && npm run build:exampleqr",
  "build:ticketqr":  "esbuild src/ticketqr.ts  --bundle --platform=node --target=node22 --format=esm --minify --external:@aws-sdk/* --outfile=dist/ticketqr/index.mjs && cp -r ../templates dist/ticketqr/ && cd dist/ticketqr && zip -qr ../ticketqr.zip .",
  "build:exampleqr": "esbuild src/exampleqr.ts --bundle --platform=node --target=node22 --format=esm --minify --outfile=dist/exampleqr/index.mjs && cd dist/exampleqr && zip -qr ../exampleqr.zip ."
}
```

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

- ローカル: `npm run dev` で `:8080`（チケット系）と `:8081`（example）を起動する。Go の `make run` / `make run-example` と同じ URL 構成で、同じアップロードフォームも出す
- zip の名前とレイアウトは Go 版と同じ（`ticketqr.zip`、`exampleqr.zip`）。CloudFormation の `Impl=node` では、`ImplMap` の Runtime と Handler（`index.handler`）だけが変わる
- 想定サイズ: バンドルは数十KB程度（Go 版の zip は 4.9MB）。コールドスタートの比較ポイントになる

### テスト方針

| 対象 | 方法 |
|---|---|
| 採番・署名 | `testdata/ticketcode.json`、`testdata/signature.json` を Go と同じテストデータとして使う |
| ハンドラー | Go の `handler_test.go` と同じケース（正常系、各エラー、PRG の流れ、署名の必須チェック、HTML のエスケープ、ルーティング） |
| QR | Node の単体テストでは、PNG のシグネチャ、IHDR のサイズ、`size <= 256` を確認する |
| QR の読み取り（両実装） | 契約テスト（`tests/contract`）で、Go と Node の両方のサーバーに同じリクエストを送り、返ってきた PNG を Go の gozxing で読み取って比べる。Node 側に QR デコーダーの dev 依存は追加しない |
| HTML の一致 | 契約テストで、同じ `ticketCode` と `sig` を指定したときの B-3 の HTML を比べる |

## 7. 後で JS に切り替える場合

`erasableSyntaxOnly` によって、TS 固有の構文は型注釈だけに限定してある。そのため、次の手順で切り替えられる。

1. 型注釈を取り除く（`esbuild --format=esm` をファイル単位でかけるか、手作業で消す）。必要なら JSDoc の型コメントと `// @ts-check` に置き換えて、`tsc --noEmit` による型チェックを残す
2. `import './lib.ts'` を `'./lib.js'` に変える
3. ビルド（esbuild）、テスト、ローカル実行の手順は変わらない

判断材料: TS のままなら、型チェックでレビューの負担が減る。JS にすれば、ビルドなしでそのまま読めるコードになる。ファイル数が少ないので、どちらにしても切り替えのコストは小さい。

## 8. 未確定・確認事項

1. Lambda ランタイムを `nodejs24.x` と `nodejs22.x` のどちらにするか（デプロイ先リージョンで使えるか）
2. 画像サイズの違い（Go は 256px、Node は 232px）を仕様として許容してよいか（推奨: 許容する）
3. JS に切り替えるかどうかを判断する時期（Go 版との比較評価と同じタイミングを推奨）
