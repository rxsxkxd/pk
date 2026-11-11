# CodeBuild プロジェクトの棚卸し: 結果データ

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

## レコード: `codebuild_project`

1 プロジェクトにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `project_name` / `project_arn` / `description` | プロジェクト名・ARN・説明 | BatchGetProjects |
| `environment_type` | ビルド環境の種類（`LINUX_CONTAINER`、`ARM_CONTAINER` など） | `environment.type` |
| `image` | ビルド環境のイメージ | `environment.image` |
| `base_os` | イメージ名を `codebuild-image-os.json` で引いたベース OS。自前のイメージは `Custom Image`、表に無いものは `Unknown` |  |
| `compute_type` / `privileged_mode` / `image_pull_credentials_type` | コンピューティングの大きさ・特権モード・イメージ取得の認証 |  |
| `service_role` | サービスロール |  |
| `source_type` / `source_location` / `source_version` | ソースの種類・場所・ブランチやコミット |  |
| `webhook` | Webhook でビルドを始める設定があれば `{build_type, filter_group_count}` |  |
| `vpc` | VPC の中でビルドするなら `{vpc_id, subnets, security_group_ids}` | `vpcConfig` |
| `timeout_in_minutes` / `queued_timeout_in_minutes` / `concurrent_build_limit` | タイムアウト・キューで待つ上限（分）・同時ビルド数の上限 |  |
| `artifacts_type` / `cache_type` | 成果物とキャッシュの種類 |  |
| `cloudwatch_logs` / `s3_logs` | ログの出力先ごとの `ENABLED` / `DISABLED` | `logsConfig` |
| `encryption_key` | 成果物を暗号化する KMS キー |  |
| `created_at` / `last_modified_at` | 作成日時と最終更新日時 |  |
| `tags` | タグ（キー → 値） |  |

## 詳細取得: `last_build`

対象: `codebuild_project`。直近のビルド。ビルドが 1 度も無ければ `null`。

| 項目 | 内容 |
|---|---|
| `build_id` | ビルド ID |
| `status` / `current_phase` | 結果（`SUCCEEDED` / `FAILED` など）と、いまのフェーズ |
| `start_time` / `end_time` | 開始と終了の日時 |
| `source_version` / `resolved_source_version` | 指定したソースの版と、実際に使ったコミット |
| `initiator` | ビルドを始めた主体 |
