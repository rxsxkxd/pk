# サブネットの棚卸し: 結果データ

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

## レコード: `subnet`

1 サブネットにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `subnet_id` / `subnet_arn` / `vpc_id` | サブネット ID・ARN・VPC | DescribeSubnets |
| `cidr_block` / `ipv6_cidr_blocks` | CIDR |  |
| `availability_zone` / `availability_zone_id` | アベイラビリティーゾーンの名前と ID |  |
| `available_ip_address_count` | 使える IP アドレスの残り |  |
| `map_public_ip_on_launch` / `default_for_az` | 起動時にパブリック IP を付けるか、デフォルトサブネットか |  |
| `state` | 状態 |  |
| `route_table_id` | 使われるルートテーブル。明示的な関連付けが無ければ VPC のメインのルートテーブル | DescribeRouteTables |
| `route_table_is_main` | メインのルートテーブルを（関連付けなしで）使っているか |  |
| `default_route_target` | 0.0.0.0/0 の行き先（`igw-`、`nat-` など）。無ければ `null` |  |
| `is_public` | 既定ルートがインターネットゲートウェイに向いているか |  |
| `tags` | タグ（キー → 値） |  |

## 詳細取得: `network_interfaces`

対象: `subnet`。サブネットにある ENI（EC2、RDS、Lambda、ALB、Fargate のタスクなど）。

| 項目 | 内容 |
|---|---|
| `network_interface_id` | ENI の ID |
| `interface_type` | 種類（`interface`、`lambda`、`nat_gateway` など） |
| `description` | 説明（作った AWS サービスが入れることが多い） |
| `requester_id` / `requester_managed` | 作った主体と、AWS が管理する ENI か |
| `status` | `in-use` / `available` |
| `private_ip_address` | プライベート IP |
| `attachment_instance_id` | アタッチされている EC2 インスタンス |
| `security_group_ids` | ENI のセキュリティグループ |
