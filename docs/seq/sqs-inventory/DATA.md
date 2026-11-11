# SQS キューの棚卸し: 結果データ

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

## レコード: `sqs_queue`

1 キューにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `queue_url` | キューの URL | ListQueues: `QueueUrls` |
| `queue_name` | キュー名（URL の最後の部分） |  |
| `fifo` | FIFO キューか（名前が `.fifo` で終わるか） |  |

## 詳細取得: `attributes`

対象: `sqs_queue`。キューの設定・溜まっているメッセージ数・デッドレターキュー・暗号化・アクセスポリシーの要約。

| 項目 | 内容 |
|---|---|
| `queue_arn` | キューの ARN |
| `visibility_timeout_sec` / `message_retention_sec` / `delay_sec` / `receive_wait_time_sec` | 可視性タイムアウト・保持期間・配信の遅延・ロングポーリングの待ち時間（秒） |
| `maximum_message_size` | メッセージの最大の大きさ（バイト） |
| `approximate_messages` / `approximate_messages_not_visible` / `approximate_messages_delayed` | 溜まっている・処理中・遅延中のメッセージのおおよその数 |
| `dead_letter_target_arn` / `max_receive_count` | デッドレターキューと、そこへ移すまでの受信回数 |
| `kms_master_key_id` / `sqs_managed_sse_enabled` | KMS による暗号化と、SQS 管理の暗号化 |
| `content_based_deduplication` | 内容による重複排除（FIFO キュー） |
| `created_at` / `last_modified_at` | 作成日時と最終更新日時 |
| `policy_statement_count` / `policy_public_statement_count` | アクセスポリシーの文の数と、そのうち条件なしでだれにでも（Principal が `*`）許可している文の数 |

## 詳細取得: `tags`

対象: `sqs_queue`。タグ（キー → 値）。
