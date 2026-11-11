# EC2 インスタンスの棚卸し

EC2 インスタンスを一覧にし、インスタンスごとに設定・ベース OS・AMI・SSM の状態を出す。OS の更新計画（Amazon Linux 2 からの移行など）や、古い AMI・IMDSv1 のままのインスタンスを探すのに使う。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/ec2-inventory.sh`](./shell/ec2-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/ec2_inventory.rb`](./ruby/sdk/ec2_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/ec2_inventory.rb`](./ruby/cli/ec2_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/ec2_inventory.py`](./python/sdk/ec2_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/ec2_inventory.py`](./python/cli/ec2_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

対応表は `tables/` が正本で、`../sync-common.sh` が各実装のディレクトリに写す。

- [`tables/ami-os-patterns.json`](./tables/ami-os-patterns.json): AMI 名 → ベース OS の対応表。上から順に正規表現を当て、最初に一致したものを使う

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/ec2-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "ec2_instance")' snapshot.jsonl \
  | ./shell/ec2-inventory.sh detail --with volumes > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby ec2_inventory.rb snapshot)
ruby ruby/cli/ec2_inventory.rb snapshot
python3 python/sdk/ec2_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/ec2_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

| オプション | 内容 |
|---|---|
| `--filter Name=...,Values=...` | DescribeInstances のフィルタ。書き方は AWS CLI の `--filters` と同じ（例: `Name=tag:env,Values=prod`、`Name=vpc-id,Values=vpc-0123`）。何回でも指定できる |

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `volumes` | `ec2_instance` | 付いている EBS ボリューム | インスタンスごとに `ec2:DescribeVolumes` を 1 回 |
| `target_health` | `ec2_instance` | ターゲットグループでのヘルス | 実行ごとに `elasticloadbalancing:DescribeTargetGroups` を 1 回と、ターゲットグループごとに `elasticloadbalancing:DescribeTargetHealth` を 1 回（同じものは使い回す） |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `ec2:DescribeInstances` を 1 回（ページ分）。終了済み（terminated）は除く
- `ec2:DescribeImages` を、使われている AMI 100 種類ごとに 1 回。登録解除済みの AMI が混ざっても失敗しないよう、ID ではなく `image-id` のフィルタで引く
- `ssm:DescribeInstanceInformation` を 1 回（ページ分）。失敗したときは各レコードの `errors` に残し、ベース OS は AMI 名から推定する

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `ec2:DescribeInstances`、`ec2:DescribeImages`、`ssm:DescribeInstanceInformation`、`sts:GetCallerIdentity`
- 詳細取得: `ec2:DescribeVolumes`、`elasticloadbalancing:DescribeTargetGroups`、`elasticloadbalancing:DescribeTargetHealth`

## 絞り込みの例

```bash
# Amazon Linux 2 以前で動いているもの
jq -r 'select(.base_os | test("^Amazon Linux( 2)?$")) | [.instance_id, .base_os, .base_os_source] | @tsv' snapshot.jsonl

# IMDSv2 を必須にしていないもの
jq -r 'select(.imds_http_tokens != "required") | .instance_id' snapshot.jsonl

# SSM の管理対象でない、または接続が切れているもの
jq -r 'select(.ssm == null or .ssm.ping_status != "Online") | .instance_id' snapshot.jsonl

# 本番のインスタンスの EBS を調べる
jq -c 'select(.tags.env == "prod")' snapshot.jsonl | ./shell/ec2-inventory.sh detail --with volumes
```

## わかっている制約

- SSM の管理対象でないインスタンスのベース OS は推定になる。AMI 名で判定できるのは、AWS などが公開している AMI から起動したものだけ。自前の AMI は `platform_details`（`Linux/UNIX` など）までしかわからない
- インスタンス名（`Name` タグ）は出さない。`tags` からも除いている
- `ami-os-patterns.json` は手で更新する。新しい OS の版が出たら追記する
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
