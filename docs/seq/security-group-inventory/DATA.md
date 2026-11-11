# セキュリティグループの棚卸し: 結果データ

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

## レコード: `security_group`

1 SG につき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `group_id` / `group_name` / `description` / `vpc_id` | SG の ID・名前・説明・VPC | DescribeSecurityGroups |
| `inbound_rules` | 受信ルール。1 行に 1 つの許可元（許可先）。`{protocol, from_port, to_port, source, source_type, description}`。protocol の `-1` はすべてのプロトコル。source_type は `cidr` / `ipv6_cidr` / `prefix_list` / `security_group` | `IpPermissions` |
| `outbound_rules` | 送信ルール（形は受信ルールと同じ） | `IpPermissionsEgress` |
| `open_to_world` | 受信ルールに 0.0.0.0/0 か ::/0 があるか |  |
| `referenced_by` | この SG をルールで参照しているほかの SG |  |
| `network_interface_count` | この SG を使っている ENI の数 | DescribeNetworkInterfaces |
| `interface_types` | 使っている ENI の種類（重複なし） |  |
| `instance_ids` | 使っている EC2 インスタンス（重複なし） |  |
| `tags` | タグ（キー → 値） |  |

## 詳細取得: `network_interfaces`

対象: `security_group`。SG を使っている ENI。

| 項目 | 内容 |
|---|---|
| `network_interface_id` | ENI の ID |
| `interface_type` | 種類（`interface`、`lambda`、`nat_gateway` など） |
| `description` | 説明（作った AWS サービスが入れることが多い） |
| `requester_id` / `requester_managed` | 作った主体と、AWS が管理する ENI か |
| `status` | `in-use` / `available` |
| `private_ip_address` | プライベート IP |
| `attachment_instance_id` | アタッチされている EC2 インスタンス |
| `subnet_id` | ENI のサブネット |
