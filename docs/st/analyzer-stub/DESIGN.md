# 画像解析サーバー スタブ 設計

API の設計は [../DESIGN.md](../DESIGN.md)（7章 画像解析サーバー連携）を参照。

> **実装状況**: スタブは Node 版（`node/`、5章）と Rust 版（`rust/`、6章）の両方が実装済み。API 側の HTTP クライアントは Go 版・Node 版とも実装済み（8章）。デプロイ手順は [../DEPLOY.md](../DEPLOY.md) 3章（スタブ）と、各実装の DEPLOY.md 4-A.3・4-B.3（API の切り替え）。

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
| 実装 | **Node 版**（`nodejs24.x`、依存なしの `index.mjs` と `analyzer.mjs`）と **Rust 版**（`provided.al2023`、`bootstrap`） | 同じ仕様で2つ実装し、API と同様に比較できるようにする |
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
- **`STUB_AUTH=none`（2026-10-07 追加）**: これを明示したときだけ、API キーを読み込まず、照合もしない。VPC 内で、SG で許可した送信元からだけ届く環境（../notes/analyzer-stub-vpc.md）で、本番の想定（API キーなし）に合わせるため
  - 未設定と `STUB_AUTH=api-key` は、今までどおり API キーが必須（キーがなければ起動に失敗する）。設定漏れで、公開した Function URL のスタブが誰でも呼べる状態にならないように、「未設定 = 確認なし」にはしない
  - それ以外の値は、起動に失敗する（打ち間違いで確認なしにならないように）
  - `none` で起動したときは、`{"level":"WARN","msg":"api key check is disabled (STUB_AUTH=none)"}` を1行ログに出す
  - Function URL で公開するテンプレート（`template.yaml`）には `STUB_AUTH` を入れない（公開のスタブは必ず API キーを使う）
  - 3つの実装とも、決まりは analyzer（Node: `NoApiKey`、Python: `NoApiKey`、Rust: `Auth::None`）に置き、選ぶのは入口（`loadAuth` / `load_auth` / `AuthSetting`）

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
├── testdata/cases.json  # Node / Rust / Python 共通のテストケース（リクエストと期待するステータス）
└── node/
    ├── package.json     # scripts: dev / test / build（依存なし）
    ├── index.mjs        # Lambda の入口（handler）。リクエストのパースと確認（ルート・Content-Type・ボディ）、ログ、応答
    ├── analyzer.mjs     # ビジネスロジック（3章の決まりごと）: API キーの照合（ApiKey）と画像の判定（analyze）。Lambda・HTTP を知らない
    ├── local.mjs        # ローカル用の HTTP サーバー（デプロイしない）
    └── test/{index,analyzer}.test.mjs
```

```sh
cd docs/st/analyzer-stub/node
npm test          # testdata/cases.json の全ケース + ヘッダー名の大文字小文字 + 応答とログの形 + API キーの読み込み + ビジネスロジック単体
npm run dev       # http://localhost:8090/v1/analyze（x-api-key: local-stub-key）
npm run build     # dist/analyzer-stub.zip（index.mjs と analyzer.mjs）
```

| 環境変数 | 内容 |
|---|---|
| `API_KEY_PARAMETER_NAME` | API キーのパラメータ名（Lambda 上では、`STUB_AUTH=none` でない限り必須） |
| `STUB_AUTH` | `api-key`（既定）/ `none`（API キーを確かめない。VPC 内で SG だけで許可する場合。3.3） |
| `APP_ENV=local` + `STUB_API_KEY` | ローカル実行・テスト用。平文の API キー（`APP_ENV=local` のときだけ使える） |
| `PORT` | `npm run dev` の待ち受けポート（既定 8090） |

組み立ては Python 版（付録）と同じ分け方で、書き方は Node の流儀（クラスではなく、モジュールの関数と、依存をオプションのオブジェクトで渡す形）: `parseRequest(event)`（イベントからスタブが見る項目を取り出す）→ `checkRequest(request, apiKey)`（仕様 3.2 の順に確かめ、通ったものだけ `analyze` に渡す）→ `respond(event, { apiKey, log })`（ログを1行出して応答に変える）。`handler` は、初回に API キーを読み込んで `respond` を呼ぶだけ。

確認済み:
- `node --test`: 18件すべて成功（2026-10-07。`STUB_AUTH` の追加の後）
- ローカル（`npm run dev`）: 200 / 401。ログの `sha256` が、送ったファイルの `shasum -a 256` と一致する
- Lambda エミュレーター（`public.ecr.aws/lambda/nodejs:24`）に Function URL 形式のイベントを送り、200 / 401 / 400 とログ出力を確認
- `template.yaml`: cfn-lint でエラー・警告なし

## 6. Rust 版（実装済み）

Node 版・Python 版と同じ仕様（3章）・同じ分け方で、`testdata/cases.json` を同じテストケースとして使う。書き方は Rust の流儀に合わせる。

```
analyzer-stub/rust/
├── Cargo.toml / Cargo.lock
├── rustfmt.toml
├── src/lib.rs           # リクエストのパースと確認（ルート・Content-Type・ボディ）、ログ、応答（StubRequest / Outcome / Stub）
├── src/analyzer.rs      # ビジネスロジック（3章の決まりごと）: API キーの照合（ApiKey）と画像の判定（analyze）。Lambda・HTTP を知らない。単体テストも同じファイル
├── src/main.rs          # Lambda の入口（bootstrap）。起動時に API キーを読み込む
├── examples/local.rs    # ローカル用の HTTP サーバー（hyper。デプロイしない。依存は dev-dependencies だけ）
├── tests/cases.rs       # 共通ケース全件 + Function URL イベント（base64 ボディ）の解析 + 応答とログの形 + API キーの読み込み
├── Dockerfile.build     # ビルド環境（Amazon Linux 2023 + rustup + rustfmt / clippy）
└── build.sh             # コンテナ内で test / lint / fmt / dev / build を実行する
```

組み立て（Node 版・Python 版との対応）:

| Rust | 役割 | Node | Python |
|---|---|---|---|
| `impl From<&Request> for StubRequest` | Function URL のリクエストから、スタブが見る項目を取り出す（ボディはコピーせずに借用する） | `parseRequest` | `Request.from_event` |
| `Stub::check` | 仕様（3.2）の順に確かめ、通ったものだけ `analyze` に渡して `Outcome` を返す | `checkRequest` | `Stub.handle` |
| `Stub::handle` | `check` の結果を分解して（所有権を移し、複製しない）ログを1行出し、応答に変える | `respond` | `Stub.__call__` |
| `analyzer::ApiKey` / `analyzer::analyze` | API キーの照合（SHA-256 にして `subtle` で定数時間比較）と画像の判定 | `ApiKey` / `analyze` | `ApiKey` / `analyze` |

| 項目 | 内容 |
|---|---|
| ランタイム | `provided.al2023`（arm64）。バイナリ名は `bootstrap` |
| 主な crate | `lambda_http` 1.3（Function URL のイベント。base64 のボディは `Body::Binary` に戻される）、`aws-sdk-ssm` 1.128 + `aws-config`、`sha2`、`subtle`（定数時間比較）、`serde_json`（`preserve_order`: ログと応答のキーを Node・Python 版と同じ順にする）、`humantime`（ログの時刻） |
| ローカル用サーバー | `examples/local.rs`。`hyper` などは dev-dependencies なので、Lambda のバイナリには入らない |
| API キー | 起動時に1回だけ読み込む（Node 版・Python 版は初回の呼び出し時）。`API_KEY_PARAMETER_NAME`、ローカルでは `APP_ENV=local` + `STUB_API_KEY`。`STUB_AUTH=none` なら読み込まない（`Auth::None`。3.3） |
| ビルド | ホストには何もインストールしない。`build.sh` が Amazon Linux 2023（arm64）のコンテナでビルドする。Lambda と同じ OS なので glibc が一致する。cargo のレジストリと `target/` は Docker ボリュームに保持する |
| サイズ | `analyzer-stub.zip` 4.4MB（ほとんどが AWS SDK。Node 版の zip は数 KB） |

```sh
cd docs/st/analyzer-stub/rust
./build.sh test     # cargo test（analyzer の単体テスト 3件 + tests/cases.rs 6件。共通ケースは1件のテストの中で全件確認する）
./build.sh lint     # cargo fmt --check と cargo clippy --all-targets（警告はエラー扱い）
./build.sh fmt      # cargo fmt（ソースを書き換える）
./build.sh dev      # http://localhost:8090/v1/analyze（x-api-key: local-stub-key。Ctrl-C で止める）
./build.sh          # cargo build --release → dist/analyzer-stub.zip
```

確認済み（2026-10-07 の組み直しの後）:
- `./build.sh test` / `./build.sh lint`: すべて成功、警告なし
- ローカル（`examples/local.rs`）: 200 / 401 / 400 / 400 / 404。応答の本文とログ（キーの順序、`requestId`、`bytes`、`sha256`）は Node 版・Python 版と同じ。ログの `sha256` は、送ったファイルの `shasum -a 256` と一致
- Lambda エミュレーター（`public.ecr.aws/lambda/provided:al2023`）に、リリースビルドの `bootstrap` で Function URL 形式のイベントを送り、200 とログを確認
- 以前あった Node 版との違い（JSON のキーの順序、`requestId` がないときに `null` を出す）は、なくなった

## 7. デプロイと削除

手順の詳細は [../DEPLOY.md](../DEPLOY.md) 3章（スタブ）と、[../go/DEPLOY.md](../go/DEPLOY.md)・[../node/DEPLOY.md](../node/DEPLOY.md) 4-A.3・4-B.3（API の切り替え）。要点は次のとおり。

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

- `ARTIFACT_BUCKET` は API と同じ成果物バケットを使う（DEPLOY.md 2章）
- 予約同時実行数は 5（パラメータ `ReservedConcurrency`）。URL が漏れても、使える量を抑えるため
- Function URL を `AuthType: NONE` で公開するには、`lambda:InvokeFunctionUrl` と `lambda:InvokeFunction`（`InvokedViaFunctionUrl: true`）の両方の権限が必要。テンプレートに両方を入れている

## 8. API 側の変更（Go 版・Node 版とも実装済み）

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

## 付録: Python 版（試作）

Node 版との比較のための試作（2026-10-07）。仕様（3章）と共通のテストケース（`testdata/cases.json`）は同じ。テンプレート（`template.yaml` の `Impl`）とデプロイ手順には、まだ入れていない。

```
analyzer-stub/python/
├── index.py          # Lambda の入口（handler: index.handler）。リクエストのパースと確認（ルート・Content-Type・ボディ）、ログ、応答
├── analyzer.py       # ビジネスロジック（仕様 3章の決まりごと）: API キーの照合と、画像の判定（スタブは解析せず valid）。Lambda・HTTP を知らない
├── local.py          # ローカル用の HTTP サーバー（標準の http.server。デプロイしない）
├── test_index.py     # 共通ケース全件 + ヘッダー名の大文字小文字 + 応答の本文とログが Node 版と同じ形 + API キーの読み込み（unittest）
└── test_analyzer.py  # ビジネスロジックだけのテスト（API キーの照合、画像の判定）
```

```sh
cd docs/st/analyzer-stub/python
python3 -m unittest -v                             # 9件（共通ケースは1件のテストの中で全件確認する）
python3 local.py                                   # http://localhost:8090/v1/analyze（x-api-key: local-stub-key）
uvx mypy --strict *.py                            # 任意: 型チェック（プロジェクトの依存には入れない）
mkdir -p dist && rm -f dist/analyzer-stub.zip && zip -q dist/analyzer-stub.zip index.py analyzer.py   # ランタイムは python3.13 以降
```

組み立て（関数の中に関数を入れ子にせず、役割ごとに分ける。リクエストの扱いとビジネスロジックはファイルを分ける）:

| ファイル | 部品 | 役割 |
|---|---|---|
| `index.py` | `Request.from_event` | Function URL のイベントから、スタブが見る項目（メソッド、パス、API キー、Content-Type、ボディ、requestId）を取り出す。ヘッダー名の小文字化と base64 の復元もここ |
| `index.py` | `Stub.handle` | 仕様（3.2）の順にリクエストを確かめ（API キーは `ApiKey.matches` で照合）、通ったものだけ `analyze` に渡して、`Outcome`（ステータス、本文、ログに足す項目）を返す。各確認は1つの `if` で早めに返す |
| `index.py` | `Stub.__call__` | `Request` を作って `handle` を呼び、1行のログを出して応答に変える |
| `index.py` | `Outcome` / `NOT_FOUND` などの定数 | 応答の形を1か所にまとめる |
| `analyzer.py` | `ApiKey` | 共有の API キー（3.3）。キーの SHA-256 だけを持ち、定数時間で比べる |
| `analyzer.py` | `analyze` / `Analysis` | 画像1枚の判定（valid / reason）と、届いた画像の大きさ・SHA-256。本物の解析サーバーの判定に当たる部分で、Lambda・HTTP には依存しない |

依存を増やさずに読みやすくするために使っている書き方（Python 3.12 以降。Lambda の `python3.13` で動く）:

| 書き方 | 使っているところ | 効果 |
|---|---|---|
| `dataclass(frozen=True)`、`Self` | `Request`・`Outcome` | 項目の一覧が型付きで読め、作ったあとに変わらない |
| 型ヒントと `type` 文（型の別名）、`TypedDict` | `Event`・`Response`・`Logger` | 関数が何を受け取り何を返すかが、読むだけで分かる。`mypy --strict` で確かめられる |
| `functools.cache` | `_stub_from_env`（初回の呼び出し時に API キーを読み込み、以降は使い回す） | `global` の変数を使わずに済む |
| `http.HTTPStatus` | 応答のステータス | `404` などの数字ではなく `NOT_FOUND` と読める |
| 代入式（`:=`） | API キーの読み込み | 「取り出して、あれば使う」が1か所で書ける |
| 辞書の結合（`|`） | ログの1行（`Stub.__call__`） | 項目の順序（Node 版と同じ）がそのまま読める |
| `str.partition` | `Content-Type` のパラメーターを外す | `split(";")[0]` より意図が明確 |
| `datetime.UTC` | ログの時刻 | `timezone.utc` より短い |
| `with ThreadingHTTPServer(...)` と `KeyboardInterrupt` の処理 | `local.py` | Ctrl-C で、エラー表示なしに止まる |
| テストを `index.py` と同じ場所に置く | `test_index.py` | `sys.path` の書き換えなしに、`python3 -m unittest` だけで動く |

確認済み:
- 単体テスト 9件すべて成功（Python 3.14 と 3.13）。`mypy --strict` でエラーなし
- ローカル（`python3 local.py`）: 200 / 401 / 400 / 404。応答の本文とログ（キーの順序、`requestId`、`bytes`、`sha256`）は Node 版と同じ形。ログの `sha256` は、送ったファイルの `shasum -a 256` と一致
