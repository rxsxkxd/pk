# Fargate で動いているタスクの棚卸し

Fargate は ECS の起動方式の 1 つで、独立した API は無い。このツールは、各クラスターで Fargate で動いているタスクを一覧にする。サービスに属さないタスク（RunTask や EventBridge のスケジュールで起動したもの）も拾える。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/fargate-inventory.sh`](./shell/fargate-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/fargate_inventory.rb`](./ruby/sdk/fargate_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/fargate_inventory.rb`](./ruby/cli/fargate_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/fargate_inventory.py`](./python/sdk/fargate_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/fargate_inventory.py`](./python/cli/fargate_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/fargate-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "fargate_task")' snapshot.jsonl \
  | ./shell/fargate-inventory.sh detail --with task_definition > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby fargate_inventory.rb snapshot)
ruby ruby/cli/fargate_inventory.rb snapshot
python3 python/sdk/fargate_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/fargate_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

| オプション | 内容 |
|---|---|
| `--cluster NAME` | 対象のクラスター（名前か ARN）。何回でも指定できる。指定しなければすべてのクラスター |

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `task_definition` | `fargate_task` | タスクが使っているタスク定義の要約 | タスク定義ごとに `ecs:DescribeTaskDefinition` を 1 回（同じものは使い回す） |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `ecs:ListClusters` を 1 回（`--cluster` を指定したときは呼ばない）
- クラスターごとに `ecs:ListTasks`（起動タイプ FARGATE。動いているもの）を 1 回（ページ分）と、100 タスクごとに `ecs:DescribeTasks`

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `ecs:ListClusters`、`ecs:ListTasks`、`ecs:DescribeTasks`、`sts:GetCallerIdentity`
- 詳細取得: `ecs:DescribeTaskDefinition`

## 絞り込みの例

```bash
# プラットフォームの版ごとのタスク数
jq -r '.platform_version' snapshot.jsonl | sort | uniq -c

# サービスに属さないタスク
jq -r 'select(.service_name == null) | [.cluster_name, .group, .started_by] | @tsv' snapshot.jsonl
```

## わかっている制約

- 動いているタスクの、取った時点の様子。止まったタスクは出ない
- キャパシティープロバイダー（FARGATE / FARGATE_SPOT）で起動したタスクも、起動タイプは FARGATE として返る
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
