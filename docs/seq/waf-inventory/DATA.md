# WAF（wafv2）の Web ACL の棚卸し: 結果データ

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

## レコード: `wafv2_web_acl`

1 Web ACL につき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `region` | REGIONAL は実行したリージョン、CLOUDFRONT は `global` |  |
| `scope` | `REGIONAL` / `CLOUDFRONT` |  |
| `name` / `id` / `arn` / `description` | Web ACL の名前・ID・ARN・説明 | ListWebACLs |

## 詳細取得: `rules`

対象: `wafv2_web_acl`。既定のアクションとルールの一覧。

| 項目 | 内容 |
|---|---|
| `default_action` | `Allow` / `Block` |
| `capacity` | 使っている WCU |
| `rules` | `{name, priority, action, statement_type, managed_rule_group, rule_group_arn}`。action はルールグループでは `override:None` のように上書きの設定を出す。managed_rule_group は `ベンダー/名前` |

## 詳細取得: `resources`

対象: `wafv2_web_acl`。Web ACL を関連付けている先。`{resource_type, resource_arn}`。

## 詳細取得: `logging`

対象: `wafv2_web_acl`。ログの出力先 `{log_destinations}`。設定していなければ `null`。
