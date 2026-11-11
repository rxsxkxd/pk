# Fargate で動いているタスクの棚卸し: 結果データ

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

## レコード: `fargate_task`

1 タスクにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `cluster_name` | クラスター名 | `clusterArn` |
| `task_arn` | タスクの ARN | DescribeTasks: `taskArn` |
| `task_definition` | 使っているタスク定義 | `taskDefinitionArn` |
| `group` | タスクのグループ（サービスのタスクなら `service:サービス名`） | `group` |
| `service_name` | サービスのタスクならサービス名。それ以外は `null` | `group` から |
| `started_by` | 起動した主体（サービス、EventBridge など） | `startedBy` |
| `last_status` / `desired_status` / `health_status` | 状態 |  |
| `capacity_provider_name` | `FARGATE` / `FARGATE_SPOT` | `capacityProviderName` |
| `platform_version` / `platform_family` | プラットフォームの版と種類 |  |
| `cpu` / `memory` | タスクの CPU とメモリ（文字列） |  |
| `ephemeral_storage_gib` | エフェメラルストレージ（GiB） | `ephemeralStorage.sizeInGiB` |
| `availability_zone` | アベイラビリティーゾーン |  |
| `subnet_id` / `private_ipv4_address` / `network_interface_id` | タスクの ENI の情報 | `attachments` の `ElasticNetworkInterface` |
| `enable_execute_command` | ECS Exec が有効か |  |
| `started_at` | 起動した日時 | `startedAt` |
| `tags` | タグ（キー → 値） |  |

## 詳細取得: `task_definition`

対象: `fargate_task`。タスクが使っているタスク定義の要約。

| 項目 | 内容 |
|---|---|
| （項目） | `../ecs-inventory/DATA.md` の `task_definition` と同じ |
