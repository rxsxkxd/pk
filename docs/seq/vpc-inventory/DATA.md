# VPC の棚卸し: 結果データ

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

## レコード: `vpc`

1 VPC につき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `vpc_id` | VPC ID | DescribeVpcs |
| `cidr_block` / `cidr_blocks` / `ipv6_cidr_blocks` | 主 CIDR、追加分を含む全 CIDR、IPv6 CIDR |  |
| `state` / `is_default` | 状態と、デフォルト VPC か |  |
| `dhcp_options_id` / `instance_tenancy` | DHCP オプションセットとテナンシー |  |
| `subnet_count` | サブネットの数 | DescribeSubnets |
| `internet_gateway_ids` | アタッチされているインターネットゲートウェイ | DescribeInternetGateways |
| `nat_gateways` | `{nat_gateway_id, subnet_id, state, connectivity_type, public_ip}` | DescribeNatGateways |
| `vpc_endpoints` | `{vpc_endpoint_id, service_name, type, state}` | DescribeVpcEndpoints |
| `peering_connections` | `{vpc_peering_connection_id, status, requester_vpc_id, accepter_vpc_id}` | DescribeVpcPeeringConnections |
| `route_tables` | `{route_table_id, main, subnet_ids, routes}`。routes は `{destination, target, state}`。target はゲートウェイ・NAT・ピアリングなどの ID | DescribeRouteTables |
| `tags` | タグ（キー → 値） |  |

## 詳細取得: `flow_logs`

対象: `vpc`。VPC に設定したフローログ。

| 項目 | 内容 |
|---|---|
| `flow_log_id` | フローログ ID |
| `traffic_type` | `ACCEPT` / `REJECT` / `ALL` |
| `log_destination_type` / `log_destination` | 出力先の種類と場所 |
| `status` / `deliver_logs_status` | フローログの状態と配信の状態 |
