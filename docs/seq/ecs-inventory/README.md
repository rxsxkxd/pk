# ECS のサービスとコンテナインスタンスの棚卸し

ECS のサービスと、EC2 起動タイプで使うコンテナインスタンス（ホスト）を一覧にする。サービスの起動方法・ロードバランサー・ネットワーク、ホストのエージェントや AMI を調べるのに使う。Fargate で動いているタスクは `../fargate-inventory/` で扱う。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/ecs-inventory.sh`](./shell/ecs-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/ecs_inventory.rb`](./ruby/sdk/ecs_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/ecs_inventory.rb`](./ruby/cli/ecs_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/ecs_inventory.py`](./python/sdk/ecs_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/ecs_inventory.py`](./python/cli/ecs_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/ecs-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "ecs_service")' snapshot.jsonl \
  | ./shell/ecs-inventory.sh detail --with task_definition > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby ecs_inventory.rb snapshot)
ruby ruby/cli/ecs_inventory.rb snapshot
python3 python/sdk/ecs_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/ecs_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

| オプション | 内容 |
|---|---|
| `--cluster NAME` | 対象のクラスター（名前か ARN）。何回でも指定できる。指定しなければすべてのクラスター |

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `task_definition` | `ecs_service` | サービスが使っているタスク定義の要約 | タスク定義ごとに `ecs:DescribeTaskDefinition` を 1 回（同じものは使い回す） |
| `tasks` | `ecs_service` | サービスのタスクと、それが動いているホスト | サービスごとに `ecs:ListTasks` を 1 回と、100 タスクごとに `ecs:DescribeTasks` |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `ecs:ListClusters` を 1 回（`--cluster` を指定したときは呼ばない）
- クラスターごとに `ecs:ListServices` を 1 回（ページ分）と、10 サービスごとに `ecs:DescribeServices`
- クラスターごとに `ecs:ListContainerInstances` を 1 回（ページ分）と、100 件ごとに `ecs:DescribeContainerInstances`

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `ecs:ListClusters`、`ecs:ListServices`、`ecs:DescribeServices`、`ecs:ListContainerInstances`、`ecs:DescribeContainerInstances`、`sts:GetCallerIdentity`
- 詳細取得: `ecs:DescribeTaskDefinition`、`ecs:ListTasks`、`ecs:DescribeTasks`

## 絞り込みの例

```bash
# 動いているタスク数が希望数に届いていないサービス
jq -r 'select(.record_type == "ecs_service" and .running_count < .desired_count) | [.cluster_name, .service_name] | @tsv' snapshot.jsonl

# エージェントが切断されているホスト
jq -r 'select(.record_type == "ecs_container_instance" and .agent_connected != true) | .ec2_instance_id' snapshot.jsonl

# あるクラスターのサービスのタスク定義を調べる
jq -c 'select(.record_type == "ecs_service" and .cluster_name == "prod")' snapshot.jsonl | ./shell/ecs-inventory.sh detail --with task_definition
```

## わかっている制約

- サービスに属さないタスク（RunTask や EventBridge のスケジュールで起動するもの）は出ない。Fargate で動いているものは `../fargate-inventory/` で拾える
- ホストのベース OS は、`ec2_instance_id` で `../ec2-inventory/` の結果と突き合わせるとわかる
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
