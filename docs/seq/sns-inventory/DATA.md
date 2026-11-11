# SNS トピックの棚卸し: 結果データ

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

## レコード: `sns_topic`

1 トピックにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `topic_arn` / `topic_name` | トピックの ARN と名前 | ListTopics |
| `fifo` | FIFO トピックか（名前が `.fifo` で終わるか） |  |
| `subscription_count` | サブスクリプションの数 | ListSubscriptions |
| `subscriptions` | `{subscription_arn, protocol, endpoint, pending_confirmation}`。endpoint はメールと SMS では `null` |  |

## 詳細取得: `attributes`

対象: `sns_topic`。暗号化・配信の状況・アクセスポリシーの要約。

| 項目 | 内容 |
|---|---|
| `display_name` | 表示名 |
| `kms_master_key_id` | 暗号化の KMS キー。暗号化していなければ `null` |
| `subscriptions_confirmed` / `subscriptions_pending` | 確認済みと確認待ちのサブスクリプションの数 |
| `content_based_deduplication` | 内容による重複排除（FIFO トピック） |
| `tracing_config` / `signature_version` | X-Ray と署名の版 |
| `policy_statement_count` / `policy_public_statement_count` | アクセスポリシーの文の数と、そのうち条件なしでだれにでも（Principal が `*`）許可している文の数 |

## 詳細取得: `tags`

対象: `sns_topic`。タグ（キー → 値）。
