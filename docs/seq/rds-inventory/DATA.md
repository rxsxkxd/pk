# RDS の DB インスタンスと DB クラスターの棚卸し: 結果データ

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

## レコード: `rds_db_instance`

1 DB インスタンスにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `db_instance_identifier` / `db_instance_arn` | DB インスタンスの識別子と ARN | DescribeDBInstances |
| `engine` / `engine_version` | エンジンと版 |  |
| `db_instance_class` | インスタンスクラス |  |
| `status` | 状態（`available` など） | `DBInstanceStatus` |
| `db_cluster_identifier` | 所属する DB クラスター（Aurora など） |  |
| `multi_az` / `availability_zone` / `secondary_availability_zone` | マルチ AZ と、置かれている AZ |  |
| `storage_type` / `allocated_storage_gib` / `iops` | ストレージの種類・容量（GiB）・IOPS |  |
| `storage_encrypted` / `kms_key_id` | ストレージの暗号化と KMS キー |  |
| `publicly_accessible` | パブリックに公開しているか |  |
| `endpoint` | `{address, port}`。作成中などで無ければ `null` | `Endpoint` |
| `vpc_id` / `db_subnet_group` | VPC と DB サブネットグループ | `DBSubnetGroup` |
| `security_group_ids` | セキュリティグループ | `VpcSecurityGroups` |
| `parameter_groups` | パラメータグループの `{name, status}`（status は反映の状態） | `DBParameterGroups` |
| `option_groups` | オプショングループ名 | `OptionGroupMemberships` |
| `backup_retention_days` / `preferred_backup_window` / `preferred_maintenance_window` | バックアップの保持日数と時間帯、メンテナンスの時間帯 |  |
| `auto_minor_version_upgrade` / `deletion_protection` | マイナーバージョンの自動更新と削除保護 |  |
| `ca_certificate_identifier` | サーバー証明書の CA |  |
| `performance_insights_enabled` / `iam_database_authentication_enabled` / `monitoring_interval` | Performance Insights・IAM 認証・拡張モニタリングの間隔（秒） |  |
| `instance_create_time` | 作成日時 |  |
| `pending_maintenance` | 保留中のメンテナンスの `{action, description, auto_applied_after, forced_apply_date, current_apply_date}` | DescribePendingMaintenanceActions |
| `tags` | タグ（キー → 値） | `TagList` |

## レコード: `rds_db_cluster`

1 DB クラスターにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `db_cluster_identifier` / `db_cluster_arn` | DB クラスターの識別子と ARN | DescribeDBClusters |
| `engine` / `engine_version` / `engine_mode` | エンジン・版・モード（`provisioned` / `serverless` など） |  |
| `status` | 状態 |  |
| `members` | 所属する DB インスタンスの `{db_instance_identifier, is_writer}` | `DBClusterMembers` |
| `multi_az` | マルチ AZ か |  |
| `endpoint` / `reader_endpoint` / `port` | 書き込み用と読み取り用のエンドポイント、ポート |  |
| `storage_encrypted` / `kms_key_id` | 暗号化と KMS キー |  |
| `db_subnet_group` / `security_group_ids` | DB サブネットグループとセキュリティグループ |  |
| `parameter_group` | DB クラスターパラメータグループ | `DBClusterParameterGroup` |
| `backup_retention_days` / `preferred_backup_window` / `preferred_maintenance_window` | バックアップとメンテナンスの設定 |  |
| `deletion_protection` / `iam_database_authentication_enabled` | 削除保護と IAM 認証 |  |
| `serverless_v2_scaling` | Aurora Serverless v2 の `{min_capacity, max_capacity}`。使っていなければ `null` |  |
| `cluster_create_time` | 作成日時 |  |
| `pending_maintenance` | 保留中のメンテナンス（`rds_db_instance` と同じ形） |  |
| `tags` | タグ（キー → 値） | `TagList` |

## 詳細取得: `parameters`

対象: `rds_db_instance, rds_db_cluster`。パラメータグループで既定から変えた値（Source=user）。

| 項目 | 内容 |
|---|---|
| `parameter_group` | パラメータグループ名 |
| `name` | パラメータ名 |
| `value` | 設定した値 |
| `apply_method` | 反映のしかた（`immediate` / `pending-reboot`） |
