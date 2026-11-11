# Lambda 関数の棚卸し: 結果データ

出力は 1 行に 1 レコードの JSON（JSONL）。この文書では、レコードの種類ごとの項目と、詳細取得で足される項目を説明する。使い方は [`README.md`](./README.md) を参照。

## どのレコードにも入る項目

| 項目 | 内容 |
|---|---|
| `record_type` | レコードの種類（下の各節の見出し） |
| `account_id` | AWS アカウント ID |
| `region` | リージョン。サービスによっては、実行したリージョンではなくリソースのあるリージョンや `global` が入る（下の表に書く） |
| `collected_at` | 一覧取得をした日時（UTC） |
| `errors` | 取得に失敗したもの。`{operation, code, message}` のリスト |

詳細取得の出力には、さらに `details_collected_at`（詳細取得をした日時）と `details`（種類 → 結果）が足される。取れなかった種類は `details` の値が `null` になり、理由が `errors` に足される。

値が無い項目は `null`、リストの項目は空の配列 `[]` になる。日時は UTC の `YYYY-MM-DDTHH:MM:SSZ` にそろえている。項目の名前と順番は、5 つの実装で同じ。

## レコード: `lambda_function`

1 関数につき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `function_name` / `function_arn` / `description` | 関数名・ARN（エイリアスやバージョンを含まない）・説明 | ListFunctions |
| `package_type` | `Zip` / `Image` | `PackageType` |
| `runtime` / `handler` | ランタイム識別子とハンドラ。コンテナイメージでは `null` |  |
| `architecture` | `x86_64` / `arm64` | `Architectures[0]` |
| `base_os` | ランタイムを `runtimes.json` で引いたベース OS。コンテナイメージは `Container Image`、表に無ければ `Unknown` |  |
| `memory_mb` / `timeout_sec` / `ephemeral_storage_mb` / `code_size_bytes` | メモリ・タイムアウト・`/tmp` の容量・パッケージの大きさ |  |
| `last_modified` | 最後に設定やコードを更新した日時 | `LastModified` |
| `role` | 実行ロール |  |
| `vpc` | VPC に接続していれば `{vpc_id, subnet_ids, security_group_ids}`、していなければ `null` | `VpcConfig` |
| `layers` | レイヤーの ARN |  |
| `environment_variable_keys` | 環境変数の名前（値は出さない） | `Environment.Variables` |
| `tracing_mode` / `log_group` / `log_format` | X-Ray のトレース、ロググループ、ログの形式 |  |
| `dead_letter_target_arn` / `kms_key_arn` / `snap_start` | デッドレターキュー、環境変数の KMS キー、SnapStart |  |
| `event_source_mappings` | SQS・Kinesis・DynamoDB Streams・Kafka などからの読み取りの `{uuid, event_source, self_managed_endpoints, topics, qualifier, state, batch_size, maximum_batching_window_sec, starting_position, filter_patterns, on_failure_destination, last_processing_result}`。qualifier はエイリアスやバージョンに付けたときの名前 | ListEventSourceMappings |

## 詳細取得: `policy`

対象: `lambda_function`。リソースベースポリシーで呼び出しを許可している相手（S3、EventBridge、API Gateway、関数 URL、他アカウントなど）。ポリシーが無ければ `[]`。

| 項目 | 内容 |
|---|---|
| `sid` / `effect` | 文の ID と Allow / Deny |
| `principal` | 呼び出し元（サービス名、IAM の ARN、`*`） |
| `action` | `lambda:InvokeFunction` や `lambda:InvokeFunctionUrl` |
| `source_arn` / `source_account` | 条件 `AWS:SourceArn` と `AWS:SourceAccount` |
| `function_url_auth_type` | 関数 URL の認証方式（`NONE` / `AWS_IAM`） |
