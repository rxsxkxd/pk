# ECS のサービスとコンテナインスタンスの棚卸し: 結果データ

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

## レコード: `ecs_service`

1 サービスにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `cluster_name` / `service_name` / `service_arn` | クラスター名・サービス名・サービスの ARN | DescribeServices |
| `status` | `ACTIVE` / `DRAINING` など | `status` |
| `launch_type` | `FARGATE` / `EC2` / `EXTERNAL`。キャパシティープロバイダーを使っているときは `null` | `launchType` |
| `capacity_provider_strategy` | キャパシティープロバイダーの `{capacity_provider, weight, base}` | `capacityProviderStrategy` |
| `platform_version` / `platform_family` | Fargate のプラットフォームの版と種類 | `platformVersion` / `platformFamily` |
| `scheduling_strategy` | `REPLICA` / `DAEMON` | `schedulingStrategy` |
| `desired_count` / `running_count` / `pending_count` | 希望するタスク数・動いている数・起動中の数 |  |
| `task_definition` | 使っているタスク定義の ARN（リビジョン付き） | `taskDefinition` |
| `load_balancers` | つながっているターゲットグループの `{target_group_arn, load_balancer_name, container_name, container_port}` | `loadBalancers` |
| `service_registries` | サービスディスカバリ（Cloud Map）の登録先 | `serviceRegistries[].registryArn` |
| `network` | `awsvpc` のときの `{subnets, security_groups, assign_public_ip}`。それ以外は `null` | `networkConfiguration.awsvpcConfiguration` |
| `deployment_circuit_breaker` | デプロイのサーキットブレーカーの `{enable, rollback}` | `deploymentConfiguration.deploymentCircuitBreaker` |
| `enable_execute_command` | ECS Exec が有効か | `enableExecuteCommand` |
| `created_at` | サービスを作った日時 | `createdAt` |
| `tags` | タグ（キー → 値） |  |

## レコード: `ecs_container_instance`

1 コンテナインスタンスにつき 1 行。値の多くは ECS エージェントが付けた属性から取る。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `cluster_name` | クラスター名 |  |
| `container_instance_arn` | コンテナインスタンスの ARN | DescribeContainerInstances |
| `ec2_instance_id` | EC2 インスタンス ID。`../ec2-inventory/` と突き合わせるときの鍵 | `ec2InstanceId` |
| `status` | `ACTIVE` / `DRAINING` など | `status` |
| `agent_connected` | ECS エージェントが接続しているか | `agentConnected` |
| `agent_version` / `docker_version` | ECS エージェントとコンテナランタイムの版 | `versionInfo` |
| `os_type` / `os_family` / `cpu_architecture` | 属性 `ecs.os-type` / `ecs.os-family` / `ecs.cpu-architecture` | `attributes` |
| `ami_id` / `instance_type` | 属性 `ecs.ami-id` / `ecs.instance-type` | `attributes` |
| `capacity_provider_name` | 所属するキャパシティープロバイダー | `capacityProviderName` |
| `running_tasks_count` / `pending_tasks_count` | 動いているタスク数・起動中のタスク数 |  |
| `registered_at` | クラスターに登録した日時 | `registeredAt` |

## 詳細取得: `task_definition`

対象: `ecs_service`。サービスが使っているタスク定義の要約。

| 項目 | 内容 |
|---|---|
| `family` / `revision` / `status` | タスク定義のファミリー・リビジョン・状態 |
| `cpu` / `memory` | タスク全体の CPU とメモリ（文字列） |
| `os_family` / `cpu_architecture` | `runtimePlatform` の OS（`LINUX` など）と CPU（`X86_64` / `ARM64`）。指定が無ければ `null` |
| `network_mode` | `awsvpc` / `bridge` / `host` など |
| `requires_compatibilities` | 対応する起動タイプ |
| `task_role_arn` / `execution_role_arn` | タスクロールとタスク実行ロール |
| `containers` | コンテナごとの `{name, image, essential, cpu, memory, memory_reservation, port_mappings, log_driver}` |

## 詳細取得: `tasks`

対象: `ecs_service`。サービスのタスクと、それが動いているホスト。

| 項目 | 内容 |
|---|---|
| `task_arn` | タスクの ARN |
| `task_definition` | タスクが使っているタスク定義（デプロイ中は新旧が混ざる） |
| `last_status` / `desired_status` / `health_status` | 状態 |
| `launch_type` | 起動タイプ |
| `container_instance_arn` | 動いているコンテナインスタンス。Fargate では `null` |
| `availability_zone` | アベイラビリティーゾーン |
| `started_at` | 起動した日時 |
