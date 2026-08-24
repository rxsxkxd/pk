# Lambda 関数の棚卸し

AWS アカウントの 1 リージョンにある Lambda 関数を一覧にし、関数ごとに設定・ベース OS・トリガーを 1 行の JSON（JSONL）で出力するツール。ランタイムの更新計画（Amazon Linux 2 からの移行など）や、どこから呼ばれている関数かの調査に使う。

同じ出力を返す実装を 3 つ置いている。環境に合わせて使いやすいものを選ぶ。

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル | [`shell/lambda-inventory.sh`](./shell/lambda-inventory.sh) | bash, AWS CLI v2, jq |
| Ruby | [`ruby/lambda_inventory.rb`](./ruby/lambda_inventory.rb) | Ruby 3.0 以上, gem `aws-sdk-lambda`（[`ruby/Gemfile`](./ruby/Gemfile)） |
| Python | [`python/lambda_inventory.py`](./python/lambda_inventory.py) | Python 3.9 以上, `boto3`（[`python/requirements.txt`](./python/requirements.txt)） |

## フォルダ構成

```
lambda-inventory/
├── README.md                  # このファイル
├── runtimes.json              # ランタイム識別子 → ベース OS の対応表（3 つの実装で共通）
├── shell/lambda-inventory.sh  # シェル版（AWS CLI + jq）
├── ruby/
│   ├── Gemfile
│   └── lambda_inventory.rb    # Ruby 版（aws-sdk-lambda）
└── python/
    ├── requirements.txt
    └── lambda_inventory.py    # Python 版（boto3）
```

## 使い方

対象のアカウントとリージョンは、AWS の標準の設定（`AWS_PROFILE`、`AWS_REGION`、`~/.aws/config` など）で決まる。結果は標準出力に出るので、ファイルに保存して jq などで絞り込む。

```bash
# シェル
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/lambda-inventory.sh > lambda.jsonl

# Ruby
cd ruby && bundle install
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 bundle exec ruby lambda_inventory.rb > ../lambda.jsonl

# Python
cd python && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 .venv/bin/python lambda_inventory.py > ../lambda.jsonl
```

複数のリージョンを調べるときは、`AWS_REGION` を変えて繰り返し実行する。

### 絞り込みの例

```bash
# Amazon Linux 2 以前で動いている関数の名前とランタイム
jq -r 'select(.base_os == "Amazon Linux 2" or .base_os == "Amazon Linux") | [.function_name, .runtime] | @tsv' lambda.jsonl

# 対応表に無いランタイム（runtimes.json への追記が必要なもの）
jq -r 'select(.base_os == "Unknown") | .runtime' lambda.jsonl | sort -u

# S3 から呼ばれる関数と、そのバケット
jq -r '.function_name as $f | .triggers[] | select(.principal == "s3.amazonaws.com") | [$f, .source_arn] | @tsv' lambda.jsonl

# 認証なし（AuthType NONE）の関数 URL を持つ関数
jq -r 'select(any(.triggers[]; .function_url_auth_type == "NONE")) | .function_name' lambda.jsonl

# 取得に失敗した関数（権限不足など）
jq -c 'select(.errors != []) | {function_name, errors}' lambda.jsonl

# CSV にする
jq -r '[.function_name, .runtime, .architecture, .base_os, (.triggers | length)] | @csv' lambda.jsonl
```

## 必要な IAM 権限

読み取りだけで、関数の設定は変えない。

- `lambda:ListFunctions`
- `lambda:ListEventSourceMappings`
- `lambda:GetPolicy`

`lambda:GetPolicy` が拒否された関数は、出力の `errors` に記録して処理を続ける。`ListFunctions` と `ListEventSourceMappings` が失敗したときは、結果が不完全になるので途中で止まる。

## API の呼び出し回数

関数の数を N とすると、呼び出しは次のとおり。

| API | 回数 |
|---|---|
| `ListFunctions` | 1 回（50 件ごとに 1 ページ） |
| `ListEventSourceMappings` | 1 回（リージョン全体をまとめて取得。100 件ごとに 1 ページ） |
| `GetPolicy` | N 回（関数ごと） |

イベントソースマッピングを関数ごとに取得すると `2N + 1` 回になるが、リージョン全体を 1 回で取得して関数 ARN で突き合わせているので `N + 2` 回で済む。出力の項目は、どれもこの 3 つの API の応答から作っており、項目を増やすために呼び出しを増やしてはいない。

スロットリングされたときは、AWS CLI と SDK の標準の再試行に任せている。

## 出力の項目

1 行に 1 関数。どの実装でも、項目の名前と順番は同じになる。値が無い項目は `null`、リストの項目は空の配列 `[]` になる。

### 関数の情報（`ListFunctions` の応答から）

| 項目 | 内容 | 例 |
|---|---|---|
| `function_name` | 関数名 | `"orders-api"` |
| `function_arn` | 関数の ARN（エイリアスやバージョンを含まない形） | `"arn:aws:lambda:ap-northeast-1:123456789012:function:orders-api"` |
| `description` | 説明 | `"注文 API"` |
| `package_type` | `Zip` か `Image`（コンテナイメージ） | `"Zip"` |
| `runtime` | ランタイム識別子。コンテナイメージでは `null` | `"python3.12"` |
| `handler` | ハンドラ。コンテナイメージでは `null` | `"app.handler"` |
| `architecture` | `x86_64` か `arm64` | `"arm64"` |
| `base_os` | ベース OS（下の「ベース OS の判定」を参照） | `"Amazon Linux 2023"` |
| `memory_mb` | メモリ（MB） | `256` |
| `timeout_sec` | タイムアウト（秒） | `30` |
| `ephemeral_storage_mb` | `/tmp` の容量（MB） | `512` |
| `code_size_bytes` | デプロイパッケージの大きさ（バイト）。コンテナイメージでは `0` | `12345` |
| `last_modified` | 最後に設定やコードを更新した日時 | `"2026-09-01T10:00:00.000+0000"` |
| `role` | 実行ロールの ARN | `"arn:aws:iam::123456789012:role/orders-api"` |
| `vpc` | VPC に接続していれば `{vpc_id, subnet_ids, security_group_ids}`、していなければ `null` | |
| `layers` | レイヤーの ARN（バージョン付き） | `["arn:aws:lambda:...:layer:common:3"]` |
| `environment_variable_keys` | 環境変数の**名前だけ**（値は秘密情報を含みうるので出さない）。名前順 | `["LOG_LEVEL", "TABLE_NAME"]` |
| `tracing_mode` | X-Ray のトレース（`Active` / `PassThrough`） | `"Active"` |
| `log_group` | ログの出力先のロググループ | `"/aws/lambda/orders-api"` |
| `log_format` | ログの形式（`Text` / `JSON`） | `"JSON"` |
| `dead_letter_target_arn` | 非同期呼び出しのデッドレターキューの ARN | |
| `kms_key_arn` | 環境変数を暗号化する、ユーザー管理の KMS キー | |
| `snap_start` | SnapStart の設定（`PublishedVersions` / `None`） | `"None"` |
| `triggers` | 呼び出し元の一覧（下の「トリガー」を参照） | |
| `errors` | 取得に失敗したもの。`{operation, code, message}` のリスト | `[]` |

### ベース OS の判定

`base_os` は次の値をとる。

| 値 | 条件 |
|---|---|
| `Amazon Linux 2023` / `Amazon Linux 2` / `Amazon Linux` | ランタイム識別子を [`runtimes.json`](./runtimes.json) で引いた結果 |
| `Container Image` | `package_type` が `Image`。OS はイメージの中身で決まるので、このツールでは判定できない |
| `Unknown` | `runtimes.json` に無いランタイム識別子 |

ランタイム識別子の名前からは OS を推測できない（例: `java8` は Amazon Linux、`java8.al2` は Amazon Linux 2。`ruby3.2` は Amazon Linux 2、`ruby3.3` は Amazon Linux 2023）。そのため正規表現は使わず、対応表で引いている。

### トリガー（`triggers`）

呼び出し元を 2 種類の情報源から集め、1 つのリストにまとめている。`type` でどちらから来たかがわかる。

**`resource_policy`**: 関数のリソースベースポリシー（`GetPolicy`）の文ごとに 1 件。S3、EventBridge、API Gateway、SNS、関数 URL、他アカウントからの呼び出しなど、Lambda を**プッシュ型で呼ぶ**ものはここに出る。

| 項目 | 内容 |
|---|---|
| `sid` | 文の ID |
| `effect` | `Allow` / `Deny` |
| `principal` | 呼び出し元。サービスなら `s3.amazonaws.com` のようなサービス名、アカウントなら IAM の ARN、だれでもなら `"*"` |
| `action` | `lambda:InvokeFunction` や `lambda:InvokeFunctionUrl` |
| `source_arn` | 条件 `AWS:SourceArn`。どのバケット・ルール・API から呼ばれるか |
| `source_account` | 条件 `AWS:SourceAccount` |
| `function_url_auth_type` | 関数 URL の認証方式（`NONE` / `AWS_IAM`）。関数 URL の文でだけ値が入る |

**`event_source_mapping`**: イベントソースマッピング（`ListEventSourceMappings`）ごとに 1 件。SQS、Kinesis、DynamoDB Streams、MSK、セルフマネージド Kafka、Amazon MQ など、Lambda がキューやストリームから**ポーリングして読む**ものはここに出る。

| 項目 | 内容 |
|---|---|
| `uuid` | マッピングの ID |
| `event_source` | 読み取り元の ARN。セルフマネージド Kafka では `null` |
| `self_managed_endpoints` | セルフマネージド Kafka のブートストラップサーバ |
| `topics` | Kafka のトピック、または Amazon MQ のキュー |
| `qualifier` | マッピングがエイリアスやバージョンに付いていればその名前。関数そのもの（`$LATEST`）なら `null` |
| `state` | `Enabled` / `Disabled` / `Creating` など |
| `batch_size` | 1 回に読む件数の上限 |
| `maximum_batching_window_sec` | まとめて読むまでの待ち時間（秒） |
| `starting_position` | ストリームを読み始める位置（`LATEST` / `TRIM_HORIZON` など） |
| `filter_patterns` | イベントのフィルタのパターン（JSON の文字列） |
| `on_failure_destination` | 処理に失敗したレコードの送り先 |
| `last_processing_result` | 最後の処理の結果（ストリームのとき） |

## わかっている制約

- **エイリアスやバージョンに付けた権限は出ない。** `GetPolicy` は修飾子を付けずに呼んでいるので、関数そのもの（`$LATEST`）のポリシーしか見ていない。API Gateway をエイリアスにつないでいる場合などは、そのトリガーは出ない。修飾子ごとに `GetPolicy` を呼ぶと、呼び出しがエイリアスとバージョンの数だけ増える。イベントソースマッピングは、エイリアスに付いたものも `qualifier` 付きで出る。
- **ポリシーにもマッピングにも残らない呼び出し元は出ない。** 呼び出し元のロールに `lambda:InvokeFunction` を許可している場合（Step Functions、別の Lambda、アプリからの SDK 呼び出しなど）は、Lambda 側に記録が無い。
- **Lambda@Edge のような、別リージョンで動く関数は出ない。** 1 回の実行で見るのは 1 リージョンだけ。
- **`runtimes.json` は手で更新する。** AWS には、ランタイムとベース OS の対応を返す API が無い。新しいランタイムが出たら、AWS ドキュメントの「Lambda ランタイム」の表を見て追記する。追記が要るランタイムは `base_os` が `Unknown` になるので、上の絞り込みの例で見つけられる。
- **シェル版の `errors` の `message` は、AWS CLI のエラー文から取り出している。** CLI の表示の形式が変わって取り出せなかったときは、`code` を `Unknown` にし、エラー文をそのまま `message` に入れる。
