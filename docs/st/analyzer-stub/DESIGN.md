# 画像解析サーバー スタブ 設計

API の設計は [../DESIGN.md](../DESIGN.md)（7章 画像解析サーバー連携）を参照。

> **実装状況**: スタブは Node 版（`node/`、5章）と Rust 版（`rust/`、6章）の両方が実装済み。API 側の HTTP クライアントは Node 版のみ実装済み（8章）。デプロイ手順は [../DEPLOY.md](../DEPLOY.md) 4.7。

## 1. 目的

- 本物の画像解析サーバーのプロトコルが決まるまでの間、**AWS Lambda 上で動き、API から実際に HTTP で呼び出せる、仮の画像解析サーバー**を用意する
- これによって、次の点を AWS 上で動作確認できるようにする
  - API 側の HTTP 版の画像解析クライアント（`ANALYZER_MODE=http`。これから実装する）
  - 画像を `application/octet-stream` でそのまま送る経路（確定済みの仕様）
  - API キーの受け渡し（Parameter Store の SecureString）
- **解析は何もしない**。受け付けた画像は常に `valid` を返す
- **本番用ではない**。動作確認が終わったら削除する。本物のサーバーの仕様が決まったら、API 側のクライアントを本物に合わせる

| 対象 | このスタブで確認する | 確認しない |
|---|---|---|
| 送信形式（POST、octet-stream、画像そのまま） | ○（受け取ったバイト数と SHA-256 をログに出す） | |
| レスポンスの解釈 | ○（`valid: true` のみ。このスタブが定める仮の形式） | 本物の形式、`valid: false` |
| 認証 | 仮の API キー（3.3） | 本物の認証方式 |
| 失敗時の挙動（invalid、5xx、タイムアウト） | | ×（API 側の単体テストで確認する。必要になったら 4章の案を実装する） |
| 画像の中身の解析 | | × |

## 2. 構成

```mermaid
flowchart LR
  B[ブラウザ / curl] --> APIGW[API Gateway<br/>ticketqr-{impl}]
  APIGW --> L[Lambda tickets<br/>ANALYZER_MODE=http]
  L -->|POST octet-stream<br/>x-api-key| FURL[Lambda Function URL]
  FURL --> S[Lambda<br/>ticketqr-analyzer-stub-{node,rust}]
  L -.-> SM[Parameter Store<br/>stub API キー（SecureString）]
  S -.-> SM
```

| 項目 | 採用 | 理由 |
|---|---|---|
| 実行環境 | Lambda（arm64、128MB、タイムアウト10秒） | API と同じ AWS アカウント・リージョンに置ける。使わないときの費用はほぼゼロ |
| 実装 | **Node 版**（`nodejs24.x`、依存なしの `index.mjs` 1ファイル）と **Rust 版**（`provided.al2023`、`bootstrap`） | 同じ仕様で2つ実装し、API と同様に比較できるようにする |
| 公開方法 | **Lambda Function URL**（`AuthType: NONE`） | API Gateway を作らずに HTTPS のエンドポイントが手に入る。アクセス制限は API キーで行う（3.3） |
| デプロイ | 共通の CloudFormation テンプレート `template.yaml`。`Impl=node|rust` で切り替え、実装ごとに別スタックにする | API のスタックとは別に作成・削除できる。zip は API と同じ成果物バケットに置く |

Function URL の代わりに IAM 認証（`AuthType: AWS_IAM`）を使う案もあるが、API 側のクライアントに SigV4 の署名処理が必要になり、本物のサーバーにはない処理をクライアントに入れることになる。そのため、仮の API キーにする。

## 3. 仮のプロトコル

本物のサーバーの仕様が決まるまでの**仮の取り決め**。確定しているのは送信形式（3.1）だけで、それ以外はこのスタブ用に決めたもの。

### 3.1 リクエスト（確定済みの仕様どおり）

```
POST {AnalyzeUrl}            （= {Function URL}/v1/analyze）
Content-Type: application/octet-stream
x-api-key: {API キー}

<画像のバイト列そのまま>
```

### 3.2 レスポンス（仮）

| ステータス | 本文 | 条件 | API 側の扱い（DESIGN.md 5.6） |
|---|---|---|---|
| 200 | `{ "valid": true, "reason": "stub" }` | 受け付けた画像はすべて（解析しない） | 採番してチケットを発行する |
| 400 | `{ "error": "..." }` | `Content-Type` が `application/octet-stream` でない、またはボディが空 | 502 `ANALYSIS_UPSTREAM_ERROR`（API 側のバグ扱い） |
| 401 | `{ "error": "invalid api key" }` | `x-api-key` がない、または一致しない | 502（設定ミス扱い） |
| 404 | `{ "error": "not found" }` | `POST /v1/analyze` 以外 | 502（設定ミス扱い） |

- 画像の形式（JPEG / PNG / HEIC など）はスタブでは見ない。形式の判定は API 側で済んでいるため
- 6MB を超えるリクエストは、Function URL が Lambda に届く前に拒否する（API 側で 4MB に制限しているので、通常は起きない）

### 3.3 認証（仮）

- `x-api-key` ヘッダーで、共有の API キーを照合する。どちらも SHA-256 にしてから定数時間で比較し、長さの違いでも時間が変わらないようにする
- API キーは Parameter Store の SecureString `/ticketqr/analyzer-stub/{impl}/api-key` に置く。CloudFormation は SecureString を作れないので、デプロイ前に CLI で作る（7章）。値はテンプレートやパラメータに書かない
- スタブと API の両方の Lambda に、このパラメータの読み取り権限（`ssm:GetParameter`）を与える。スタブは初回の呼び出し時にキーを読み込み、メモリに保持する

### 3.4 ログ

1リクエストにつき1行の JSON ログを出す。**画像そのものは保存もログ出力もしない。**

```json
{"time":"…","level":"INFO","msg":"analyzed","requestId":"…","status":200,"bytes":10240,"sha256":"…","valid":true}
```

- `bytes` と `sha256` で、API が画像を加工せずにそのまま送っていることを確かめる（ブラウザで送ったファイルの `shasum -a 256` と比べる）

## 4. 案（未実装）: シナリオの切り替え

API 側の失敗時の挙動（422 / 502 / 504、リトライ）も AWS 上で確認したくなった場合に追加する仕組み。今は実装しない。

**画像のバイト列に含まれる目印**で挙動を切り替える。API は画像をそのまま送るので、ブラウザから送った画像の目印がスタブまで届く。

| 画像に含まれる ASCII 文字列 | 挙動 | API 側の結果 |
|---|---|---|
| （目印なし） | `STUB_DEFAULT`（既定は `valid`）に従う | 発行 |
| `STUB:VALID` | 200 `{ "valid": true }` | 発行 |
| `STUB:INVALID` | 200 `{ "valid": false, "reason": "stub: marked invalid" }` | 422 `IMAGE_INVALID` |
| `STUB:ERROR` | 500 | リトライ1回のあと 502 |
| `STUB:TIMEOUT` | `STUB_TIMEOUT_MS`（既定 8000ms）待ってから 200 | 504 `ANALYSIS_TIMEOUT`（API 側のタイムアウトは5秒） |
| `STUB:SLOW` | `STUB_SLOW_MS`（既定 2000ms）待ってから 200 | 発行（タイムアウトにならない遅延の確認用） |

- 目印は、JPEG なら末尾（EOI マーカーの後ろ）、PNG なら `IEND` チャンクの後ろに付け足す。どちらも画像としては壊れず、API の形式判定（先頭バイト）も通る
  ```sh
  cp sample.jpg invalid.jpg && printf 'STUB:INVALID' >> invalid.jpg
  ```
- 追加する環境変数: `STUB_DEFAULT`（`valid` / `invalid` / `error`）、`STUB_TIMEOUT_MS`、`STUB_SLOW_MS`。`STUB_TIMEOUT_MS` は Lambda のタイムアウト（10秒）より短くする
- 別案: スタブの環境変数だけで、デプロイ単位に挙動を固定する。実装は簡単だが、E2E で複数のシナリオを一度に試せない

## 5. Node 版（実装済み）

```
analyzer-stub/
├── DESIGN.md            # 本書
├── template.yaml        # CloudFormation（Impl=node|rust）
├── testdata/cases.json  # Node / Rust 共通のテストケース（リクエストと期待するステータス）
└── node/
    ├── package.json     # scripts: dev / test / build（依存なし）
    ├── index.mjs        # スタブ本体（Lambda の handler）
    ├── local.mjs        # ローカル用の HTTP サーバー（デプロイしない）
    └── test/index.test.mjs
```

```sh
cd docs/st/analyzer-stub/node
npm test          # testdata/cases.json の全ケース + ヘッダー名の大文字小文字 + API キーの読み込み
npm run dev       # http://localhost:8090/v1/analyze（x-api-key: local-stub-key）
npm run build     # dist/analyzer-stub.zip（index.mjs のみ）
```

| 環境変数 | 内容 |
|---|---|
| `API_KEY_PARAMETER_NAME` | API キーのパラメータ名（Lambda 上では必須） |
| `APP_ENV=local` + `STUB_API_KEY` | ローカル実行・テスト用。平文の API キー（`APP_ENV=local` のときだけ使える） |
| `PORT` | `npm run dev` の待ち受けポート（既定 8090） |

確認済み:
- `node --test`: 12件すべて成功
- ローカル（`npm run dev`）: 200 / 401。ログの `sha256` が、送ったファイルの `shasum -a 256` と一致する
- Lambda エミュレーター（`public.ecr.aws/lambda/nodejs:24`）に Function URL 形式のイベントを送り、200 / 401 / 400 とログ出力を確認
- `template.yaml`: cfn-lint でエラー・警告なし

## 6. Rust 版（実装済み）

Node 版と同じ仕様（3章）で、`testdata/cases.json` を同じテストケースとして使う。

```
analyzer-stub/rust/
├── Cargo.toml / Cargo.lock
├── rustfmt.toml
├── src/lib.rs           # Stub（リクエストの検証と応答。テストから直接呼べる）
├── src/main.rs          # Lambda の入口（bootstrap）。起動時に API キーを読み込む
├── tests/cases.rs       # 共通ケース全件 + Function URL イベント（base64 ボディ）の解析 + API キーの読み込み
├── Dockerfile.build     # ビルド環境（Amazon Linux 2023 + rustup + rustfmt / clippy）
└── build.sh             # コンテナ内で test / lint / build を実行する
```

| 項目 | 内容 |
|---|---|
| ランタイム | `provided.al2023`（arm64）。バイナリ名は `bootstrap` |
| 主な crate | `lambda_http` 1.3（Function URL のイベント。base64 のボディは `Body::Binary` に戻される）、`aws-sdk-ssm` 1.128 + `aws-config`、`sha2`、`subtle`（定数時間比較）、`serde_json`、`humantime`（ログの時刻） |
| API キー | 起動時に1回だけ読み込む（Node 版は初回の呼び出し時）。`API_KEY_PARAMETER_NAME`、ローカルでは `APP_ENV=local` + `STUB_API_KEY` |
| ビルド | ホストには何もインストールしない。`build.sh` が Amazon Linux 2023（arm64）のコンテナでビルドする。Lambda と同じ OS なので glibc が一致する。cargo のレジストリと `target/` は Docker ボリュームに保持する |
| サイズ | `analyzer-stub.zip` 4.5MB（`bootstrap` 9.4MB。ほとんどが AWS SDK。Node 版の zip は 1KB 程度） |

```sh
cd docs/st/analyzer-stub/rust
./build.sh test     # cargo test（3件。共通ケースは1件のテストの中で全件確認する）
./build.sh lint     # cargo fmt --check と cargo clippy（警告はエラー扱い）
./build.sh          # cargo build --release → dist/analyzer-stub.zip
```

確認済み:
- `./build.sh test` / `./build.sh lint`: すべて成功、警告なし
- Lambda エミュレーター（`public.ecr.aws/lambda/provided:al2023`）に Function URL 形式のイベントを送り、Node 版と同じ結果（200 / 401 / 401 / 400 / 404 / 400）とログ（`bytes`、`sha256`、`requestId`）を確認
- Node 版との違いは、レスポンスの JSON のキーの順序（Rust は `{"reason":…,"valid":…}`）と、ログのキーの順序だけ

## 7. デプロイと削除

手順の詳細は [../DEPLOY.md](../DEPLOY.md) 4.7。要点は次のとおり。

```sh
cd docs/st
export STUB_IMPL=node                                        # Rust 版なら: rust
export ANALYZER_KEY_PARAM=/ticketqr/analyzer-stub/$STUB_IMPL/api-key

# 1. API キーを Parameter Store の SecureString に作る（初回だけ。CloudFormation は SecureString を作れない）
umask 077; KEY_FILE=$(mktemp); openssl rand -hex 20 | tr -d '\n' > "$KEY_FILE"
aws ssm put-parameter --name $ANALYZER_KEY_PARAM --type SecureString --value file://"$KEY_FILE"
rm -f "$KEY_FILE"

# 2. ビルドしてアップロードし、スタックをデプロイする
npm --prefix analyzer-stub/node run build                    # Rust 版なら: analyzer-stub/rust/build.sh
export STUB_PREFIX=analyzer-stub/$STUB_IMPL/$(git rev-parse --short HEAD)
aws s3 cp analyzer-stub/$STUB_IMPL/dist/analyzer-stub.zip s3://$ARTIFACT_BUCKET/$STUB_PREFIX/analyzer-stub.zip
aws cloudformation deploy --stack-name ticketqr-analyzer-stub-$STUB_IMPL \
  --template-file analyzer-stub/template.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides Impl=$STUB_IMPL ArtifactBucket=$ARTIFACT_BUCKET ArtifactPrefix=$STUB_PREFIX \
    ApiKeyParameterName=$ANALYZER_KEY_PARAM

# 出力: AnalyzeUrl（API の ANALYZER_URL）、ApiKeyParameterName（API の AnalyzerApiKeyParameterName）
ANALYZE_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-analyzer-stub-$STUB_IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='AnalyzeUrl'].OutputValue" --output text)

# 3. 動作確認
KEY=$(aws ssm get-parameter --name $ANALYZER_KEY_PARAM --with-decryption --query Parameter.Value --output text)
curl -s -X POST -H 'content-type: application/octet-stream' -H "x-api-key: $KEY" --data-binary @testdata/images/photo.jpg "$ANALYZE_URL"

# 4. 確認が終わったら削除する（API キーはスタックの外にあるので別に削除する）
aws cloudformation delete-stack --stack-name ticketqr-analyzer-stub-$STUB_IMPL
aws ssm delete-parameter --name $ANALYZER_KEY_PARAM
```

- `ARTIFACT_BUCKET` は API と同じ成果物バケットを使う（DEPLOY.md 4.2）
- 予約同時実行数は 5（パラメータ `ReservedConcurrency`）。URL が漏れても、使える量を抑えるため
- Function URL を `AuthType: NONE` で公開するには、`lambda:InvokeFunctionUrl` と `lambda:InvokeFunction`（`InvokedViaFunctionUrl: true`）の両方の権限が必要。テンプレートに両方を入れている

## 8. API 側の変更（Node 版は実装済み、Go 版は未着手）

| 対象 | 内容 |
|---|---|
| 画像解析クライアント | `ANALYZER_MODE=http` を追加する。`ANALYZER_URL` に POST する（octet-stream、`x-api-key` 付き）。接続1秒・全体5秒でタイムアウトし、5xx とタイムアウトのときだけ1回リトライする（DESIGN.md 7章） |
| 設定 | `ANALYZER_URL`、`ANALYZER_API_KEY_PARAMETER_NAME` を追加する |
| エラーの変換 | タイムアウト → `ANALYSIS_TIMEOUT`（504）、それ以外の失敗 → 502、`valid: false` → 422。すでに `AnalyzerError`（Node）と `ErrUpstream` / `ErrTimeout`（Go）で用意してある |
| CloudFormation（`infra/cloudformation/api.yaml`） | パラメータ `AnalyzerUrl`、`AnalyzerApiKeyParameterName` を追加する。Lambda の環境変数と、パラメータの読み取り権限を追加する |
| テスト | API のテストでは、ローカルの HTTP サーバー（このスタブの `local.mjs` など）を立てて、クライアントの挙動（タイムアウト、リトライ、エラーの変換）を確かめる |

レスポンスの形式（3.2）は仮のものなので、クライアント側では解釈部分を1か所にまとめ、本物の仕様が決まったらそこだけを差し替える。

Node 版の実装（`node/src/infra.ts`）:

| 項目 | 内容 |
|---|---|
| `newAnalyzer(env)` | `ANALYZER_MODE=mock` → プロセス内のモック、`http` → `httpAnalyzer`。`http` のときは `ANALYZER_URL`（必須）、`ANALYZER_API_KEY_PARAMETER_NAME`（Lambda 上。ローカルは `APP_ENV=local` + `ANALYZER_API_KEY`）、`ANALYZER_TIMEOUT_MS`（既定 5000）を読む |
| `httpAnalyzer` | 標準の `fetch` で POST する（依存なし）。1回ごとに `AbortSignal.timeout` で打ち切る。5xx・タイムアウト・通信エラーのときだけ1回リトライし、4xx と形式の崩れたレスポンスはリトライしない |
| `parseAnalyzerResponse` | 仮の形式 `{valid: boolean, reason?: string}` の解釈。本物の仕様が決まったら、ここだけを差し替える |
| テスト | `node/test/app.test.ts` の `http analyzer client`。ローカルの HTTP サーバーを立てて、送ったバイト列とヘッダー、リトライの回数、タイムアウト、API のエラー（422 / 502 / 504）への変換を確認する |

ローカルでの通し確認（スタブの `npm run dev` + API の `ANALYZER_MODE=http`）: 発行（201 / 303）が通り、スタブのログの SHA-256 が送った画像と一致した。スタブを止めたとき・API キーが違うときは 502 になった。

## 9. 決めておきたいこと

1. 仮のレスポンス形式（3.2）と認証（3.3）を、この内容で進めてよいか
2. Go 版の HTTP クライアントに着手する時期（Node 版は実装済み）
