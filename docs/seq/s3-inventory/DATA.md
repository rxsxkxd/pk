# S3 バケットの棚卸し: 結果データ

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

## レコード: `s3_bucket`

1 バケットにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `region` | バケットのあるリージョン（実行したリージョンではない） | ListBuckets: `BucketRegion` |
| `bucket_name` | バケット名 | `Name` |
| `creation_date` | 作成日時 | `CreationDate` |

## 詳細取得: `security`

対象: `s3_bucket`。暗号化・パブリックアクセスブロック・バケットポリシーの公開状態・オブジェクトの所有者。

| 項目 | 内容 |
|---|---|
| `encryption` | 既定の暗号化の `{algorithm, kms_key_id, bucket_key_enabled}`。設定が無ければ `null` |
| `public_access_block` | バケットのパブリックアクセスブロックの 4 つの設定。設定が無ければ `null`（アカウント全体の設定はここには出ない） |
| `has_policy` | バケットポリシーがあるか |
| `policy_is_public` | バケットポリシーが公開になっているか。ポリシーが無ければ `null` |
| `object_ownership` | オブジェクトの所有者の設定（`BucketOwnerEnforced` など）。設定が無ければ `null` |

## 詳細取得: `management`

対象: `s3_bucket`。バージョニング・ライフサイクル・アクセスログ。

| 項目 | 内容 |
|---|---|
| `versioning` | `Enabled` / `Suspended`。一度も有効にしていなければ `null` |
| `mfa_delete` | MFA Delete の設定 |
| `lifecycle_rule_count` / `lifecycle_enabled_rule_count` | ライフサイクルルールの数と、そのうち有効なものの数 |
| `logging_target_bucket` / `logging_target_prefix` | サーバーアクセスログの出力先。設定が無ければ `null` |

## 詳細取得: `tags`

対象: `s3_bucket`。タグ（キー → 値）。付いていなければ `{}`。
