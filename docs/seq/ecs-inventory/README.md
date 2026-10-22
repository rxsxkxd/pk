# ECS の棚卸し

AWS アカウントの 1 リージョンにある ECS のサービスとコンテナインスタンスを一覧にし、1 件 1 行の JSON（JSONL）で出力するツール。サービスがどのタスク定義・イメージ・OS・CPU アーキテクチャで動いているか、どのロードバランサーにつながっているか、EC2 起動タイプのホストのエージェントや AMI が古くないかを調べるのに使う。

同じ出力を返す実装を 3 つ置いている。環境に合わせて使いやすいものを選ぶ。

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル | [`shell/ecs-inventory.sh`](./shell/ecs-inventory.sh) | bash, AWS CLI v2, jq |
| Ruby | [`ruby/ecs_inventory.rb`](./ruby/ecs_inventory.rb) | Ruby 3.0 以上, gem `aws-sdk-ecs`（[`ruby/Gemfile`](./ruby/Gemfile)） |
| Python | [`python/ecs_inventory.py`](./python/ecs_inventory.py) | Python 3.9 以上, `boto3`（[`python/requirements.txt`](./python/requirements.txt)） |

## フォルダ構成

```
ecs-inventory/
├── README.md                 # このファイル
├── shell/ecs-inventory.sh    # シェル版（AWS CLI + jq）
├── ruby/
│   ├── Gemfile
│   └── ecs_inventory.rb      # Ruby 版（aws-sdk-ecs）
└── python/
    ├── requirements.txt
    └── ecs_inventory.py      # Python 版（boto3）
```

## 使い方

対象のアカウントとリージョンは、AWS の標準の設定（`AWS_PROFILE`、`AWS_REGION`、`~/.aws/config` など）で決まる。結果は標準出力に出るので、ファイルに保存して jq などで絞り込む。

```bash
# シェル
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/ecs-inventory.sh > ecs.jsonl

# Ruby
cd ruby && bundle install
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 bundle exec ruby ecs_inventory.rb > ../ecs.jsonl

# Python
cd python && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 .venv/bin/python ecs_inventory.py > ../ecs.jsonl
```

### 絞り込みの例

```bash
# サービスごとの起動タイプ・OS・アーキテクチャ
jq -r 'select(.record_type == "service") | [.cluster_name, .service_name, (.launch_type // "capacity provider"), .os_family, .cpu_architecture] | @tsv' ecs.jsonl

# サービスが使っているコンテナイメージ（重複を除く）
jq -r 'select(.record_type == "service") | .containers[].image' ecs.jsonl | sort -u

# 動いているタスク数が希望数に届いていないサービス
jq -r 'select(.record_type == "service" and .running_count < .desired_count) | [.cluster_name, .service_name, .running_count, .desired_count] | @tsv' ecs.jsonl

# エージェントが切断されているコンテナインスタンス
jq -r 'select(.record_type == "container_instance" and .agent_connected != true) | [.cluster_name, .ec2_instance_id] | @tsv' ecs.jsonl

# コンテナインスタンスのベース OS を、EC2 の棚卸しの結果（../ec2-inventory）と突き合わせる
jq -r --slurpfile ec2 ec2.jsonl '
  select(.record_type == "container_instance")
  | .ec2_instance_id as $id
  | [.cluster_name, $id, .agent_version, (first($ec2[] | select(.instance_id == $id) | .base_os) // "不明")]
  | @tsv' ecs.jsonl
```

## 必要な IAM 権限

読み取りだけで、サービスやタスクは変えない。

- `ecs:ListClusters`
- `ecs:ListServices`
- `ecs:DescribeServices`
- `ecs:ListContainerInstances`
- `ecs:DescribeContainerInstances`
- `ecs:DescribeTaskDefinition`

`ecs:DescribeTaskDefinition` が失敗したタスク定義は、それを使うサービスの `errors` に記録し、タスク定義由来の項目を `null` にして続ける。それ以外の呼び出しが失敗したときは、結果が不完全になるので途中で止まる。

## API の呼び出し回数

| API | 回数 |
|---|---|
| `ListClusters` | 1 回（ページ分） |
| `ListServices` | クラスターごとに 1 回（ページ分） |
| `DescribeServices` | クラスターごとに、サービスを 10 件ずつまとめた回数 |
| `ListContainerInstances` | クラスターごとに 1 回（ページ分） |
| `DescribeContainerInstances` | クラスターごとに、コンテナインスタンスを 100 件ずつまとめた回数 |
| `DescribeTaskDefinition` | サービスが使っているタスク定義の種類の数 |

まとめて取得できない API は `DescribeTaskDefinition` だけで、同じタスク定義を使うサービスが複数あっても 1 回しか引かない。タスク（`ListTasks` / `DescribeTasks`）は引いていないので、タスクの数には左右されない。

## 出力の項目

レコードは 2 種類あり、`record_type` で見分ける。先にすべてのサービス、続けてすべてのコンテナインスタンスが出る。どの実装でも、項目の名前と順番は同じになる。値が無い項目は `null`、リストの項目は空の配列 `[]` になる。日時は UTC の `YYYY-MM-DDTHH:MM:SSZ` にそろえている。

### サービス（`record_type: "service"`）

サービスの設定（`DescribeServices`）と、そのサービスが今使っているタスク定義（`DescribeTaskDefinition`）を 1 件にまとめている。

| 項目 | 内容 |
|---|---|
| `cluster_name` / `service_name` / `service_arn` | クラスター名・サービス名・サービスの ARN |
| `status` | `ACTIVE` / `DRAINING` など |
| `launch_type` | `FARGATE` / `EC2` / `EXTERNAL`。キャパシティープロバイダーを使っているときは `null` |
| `capacity_provider_strategy` | キャパシティープロバイダーの `{capacity_provider, weight, base}` のリスト |
| `platform_version` / `platform_family` | Fargate のプラットフォームの版と種類（例: `1.4.0`、`Linux`） |
| `scheduling_strategy` | `REPLICA` / `DAEMON` |
| `desired_count` / `running_count` / `pending_count` | 希望するタスク数・動いている数・起動中の数 |
| `task_definition` | 使っているタスク定義の ARN（リビジョン付き） |
| `cpu` / `memory` | タスク全体の CPU とメモリ（タスク定義の値。文字列） |
| `os_family` | タスク定義の `runtimePlatform.operatingSystemFamily`（`LINUX`、`WINDOWS_SERVER_2022_CORE` など）。指定していなければ `null` |
| `cpu_architecture` | タスク定義の `runtimePlatform.cpuArchitecture`（`X86_64` / `ARM64`）。指定していなければ `null` |
| `network_mode` | `awsvpc` / `bridge` / `host` など |
| `requires_compatibilities` | タスク定義が対応する起動タイプ |
| `task_role_arn` / `execution_role_arn` | タスクロールとタスク実行ロール |
| `containers` | コンテナごとの `{name, image, essential, cpu, memory, memory_reservation, port_mappings, log_driver, environment_variable_keys, secret_names}` |
| `load_balancers` | つながっているターゲットグループの `{target_group_arn, load_balancer_name, container_name, container_port}` |
| `service_registries` | サービスディスカバリ（Cloud Map）の登録先の ARN |
| `network` | `awsvpc` のときの `{subnets, security_groups, assign_public_ip}`。それ以外は `null` |
| `deployment_circuit_breaker` | デプロイのサーキットブレーカーの `{enable, rollback}` |
| `enable_execute_command` | ECS Exec が有効か |
| `created_at` | サービスを作った日時 |
| `errors` | 取得に失敗したもの。`{operation, code, message}` のリスト |

環境変数とシークレットは**名前だけ**を出す。値は秘密情報を含みうるので出さない。

`os_family` と `cpu_architecture` は、タスク定義に書いた値をそのまま出している。Fargate では指定が無ければ `LINUX` / `X86_64` で動く。EC2 起動タイプでは、実際にはタスクが置かれたホストで決まる。

### コンテナインスタンス（`record_type: "container_instance"`）

EC2 起動タイプやキャパシティープロバイダーで、クラスターに登録されている EC2 インスタンス。値の多くは、ECS エージェントが登録時に付けた属性から取っている。

| 項目 | 内容 |
|---|---|
| `cluster_name` | クラスター名 |
| `container_instance_arn` | コンテナインスタンスの ARN |
| `ec2_instance_id` | EC2 インスタンス ID。EC2 の棚卸しの結果と突き合わせるときの鍵になる |
| `status` | `ACTIVE` / `DRAINING` など |
| `agent_connected` | ECS エージェントが接続しているか |
| `agent_version` / `docker_version` | ECS エージェントとコンテナランタイムの版 |
| `os_type` | 属性 `ecs.os-type`（`linux` / `windows`） |
| `os_family` | 属性 `ecs.os-family`（`LINUX`、`WINDOWS_SERVER_2022_FULL` など） |
| `cpu_architecture` | 属性 `ecs.cpu-architecture` |
| `ami_id` | 属性 `ecs.ami-id`。ホストの起動に使った AMI |
| `instance_type` | 属性 `ecs.instance-type` |
| `capacity_provider_name` | 所属するキャパシティープロバイダー |
| `running_tasks_count` / `pending_tasks_count` | 動いているタスク数・起動中のタスク数 |
| `registered_at` | クラスターに登録した日時 |
| `errors` | いまは常に `[]`（サービスのレコードと形をそろえるため） |

## わかっている制約

- **サービスに属さないタスクは出ない。** `RunTask` で直接起動するタスク、EventBridge のスケジュールや Step Functions から起動するタスクは、サービスではないので含まれない。スケジュールされたタスクを拾うには EventBridge のルールとターゲットを別に引く必要があり、呼び出しが増える。
- **サービスとホストの対応は出さない。** どのタスクがどのコンテナインスタンスで動いているかは、タスクを引かないとわからない。クラスター名で突き合わせる。
- **コンテナの中の OS はわからない。** `os_family` はタスクを動かす環境の OS で、コンテナイメージのベース OS（Debian、Alpine など）ではない。イメージの中身はこのツールでは調べない。
- **デプロイ中の新旧のタスク定義は、サービスの今の値だけを出す。** ローリング更新の途中では、古いタスク定義で動くタスクが残っていることがある。
- **1 回の実行で見るのは 1 リージョンだけ。**
