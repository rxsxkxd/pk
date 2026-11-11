# EC2 インスタンスの棚卸し: 結果データ

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

## レコード: `ec2_instance`

1 インスタンスにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `instance_id` | インスタンス ID | DescribeInstances: `InstanceId` |
| `state` | `pending` / `running` / `stopping` / `stopped` / `shutting-down` | `State.Name` |
| `instance_type` | インスタンスタイプ | `InstanceType` |
| `architecture` | `x86_64` / `arm64` | `Architecture` |
| `platform_details` | 課金上のプラットフォーム（`Linux/UNIX`、`Windows` など） | `PlatformDetails` |
| `base_os` | ベース OS（例: `Amazon Linux 2023`、`Ubuntu 22.04`） | 下の `base_os_source` の順で決める |
| `base_os_source` | `base_os` を何から決めたか。`ssm`（SSM エージェントの報告）→ `ami_name`（AMI 名と対応表）→ `platform_details` の順に見る |  |
| `image_id` | 起動に使った AMI の ID | `ImageId` |
| `image` | AMI の `{name, description, owner_id, creation_date, deprecation_time}`。登録解除済みなら `null` | DescribeImages |
| `launch_time` | 最後に起動した日時 | `LaunchTime` |
| `availability_zone` | アベイラビリティーゾーン | `Placement.AvailabilityZone` |
| `vpc_id` / `subnet_id` | VPC とサブネット | `VpcId` / `SubnetId` |
| `private_ip_address` / `public_ip_address` | IP アドレス。パブリック IP が無ければ `null` |  |
| `security_group_ids` | セキュリティグループ | `SecurityGroups[].GroupId` |
| `iam_instance_profile_arn` | インスタンスプロファイル | `IamInstanceProfile.Arn` |
| `key_name` | キーペア名 | `KeyName` |
| `imds_http_tokens` | `required` なら IMDSv2 のみ、`optional` なら IMDSv1 も使える | `MetadataOptions.HttpTokens` |
| `monitoring_state` | 詳細モニタリング（`enabled` / `disabled`） | `Monitoring.State` |
| `auto_scaling_group` | 所属する Auto Scaling グループ | タグ `aws:autoscaling:groupName` |
| `launch_template` | 起動に使った起動テンプレートの `{id, version}` | タグ `aws:ec2launchtemplate:*` |
| `ssm` | SSM エージェントの `{ping_status, agent_version, platform_type, last_ping_at}`。管理対象でなければ `null` | DescribeInstanceInformation |
| `tags` | `Name` 以外のタグ（キー → 値） | `Tags` |

## 詳細取得: `volumes`

対象: `ec2_instance`。付いている EBS ボリューム。

| 項目 | 内容 |
|---|---|
| `volume_id` | ボリューム ID |
| `device` | デバイス名（例: `/dev/xvda`） |
| `size_gib` | 大きさ（GiB） |
| `volume_type` | 種類（`gp3` など） |
| `iops` | IOPS |
| `throughput` | スループット（MiB/秒） |
| `encrypted` | 暗号化されているか |
| `kms_key_id` | 暗号化に使う KMS キー |
| `delete_on_termination` | インスタンスの終了時に削除されるか |
| `state` | ボリュームの状態 |

## 詳細取得: `target_health`

対象: `ec2_instance`。ターゲットグループでのヘルス。

| 項目 | 内容 |
|---|---|
| `target_group_arn` | 登録されているターゲットグループ |
| `port` | ポート |
| `state` | ヘルス（`healthy` / `unhealthy` など） |
| `reason` | ヘルスの理由のコード |
