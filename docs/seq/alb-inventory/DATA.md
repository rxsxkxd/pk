# ロードバランサー（ALB）とターゲットグループの棚卸し: 結果データ

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

## レコード: `elbv2_load_balancer`

1 ロードバランサーにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `load_balancer_name` / `load_balancer_arn` | 名前と ARN | DescribeLoadBalancers |
| `type` | `application` / `network` / `gateway` |  |
| `scheme` | `internet-facing` / `internal` |  |
| `state` | 状態（`active` など） | `State.Code` |
| `dns_name` / `vpc_id` / `ip_address_type` | DNS 名・VPC・IP の種類 |  |
| `availability_zones` | `{zone_name, subnet_id}` |  |
| `security_group_ids` | セキュリティグループ（NLB では付けていなければ空） |  |
| `created_time` | 作成日時 |  |
| `target_group_arns` | このロードバランサーにつながっているターゲットグループ | DescribeTargetGroups |
| `tags` | タグ（キー → 値） | DescribeTags |

## レコード: `elbv2_target_group`

1 ターゲットグループにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `target_group_name` / `target_group_arn` | 名前と ARN | DescribeTargetGroups |
| `target_type` | `instance` / `ip` / `lambda` / `alb` |  |
| `protocol` / `port` / `vpc_id` | プロトコル・ポート・VPC |  |
| `health_check` | `{protocol, path, port, interval_sec, timeout_sec, healthy_threshold, unhealthy_threshold, matcher}` |  |
| `load_balancer_arns` | つながっているロードバランサー |  |
| `tags` | タグ（キー → 値） | DescribeTags |

## 詳細取得: `listeners`

対象: `elbv2_load_balancer`。リスナーと、その振り分けルール。

| 項目 | 内容 |
|---|---|
| `listener_arn` / `protocol` / `port` | リスナー |
| `ssl_policy` / `certificate_arns` | TLS のポリシーと証明書 |
| `default_actions` | 既定のアクション。`{type, target_group_arns, redirect_status, fixed_response_status}` |
| `rules` | `{priority, is_default, conditions, actions}`。conditions は `{field, values}` |

## 詳細取得: `attributes`

対象: `elbv2_load_balancer`。ロードバランサーの属性（削除保護・アクセスログ・アイドルタイムアウトなど）をキー → 値で。

## 詳細取得: `target_health`

対象: `elbv2_target_group`。登録されたターゲットとそのヘルス。

| 項目 | 内容 |
|---|---|
| `target_id` / `port` / `availability_zone` | ターゲット（インスタンス ID、IP、Lambda の ARN など） |
| `state` / `reason` / `description` | ヘルスと、その理由 |
