# サブネットの棚卸し

サブネットを一覧にし、関連付けられたルートテーブルから、パブリックかどうかと既定ルートの行き先を出す。IP アドレスの残りや、どこに何が置かれているかを調べるのに使う。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/subnet-inventory.sh`](./shell/subnet-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/subnet_inventory.rb`](./ruby/sdk/subnet_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/subnet_inventory.rb`](./ruby/cli/subnet_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/subnet_inventory.py`](./python/sdk/subnet_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/subnet_inventory.py`](./python/cli/subnet_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/subnet-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "subnet")' snapshot.jsonl \
  | ./shell/subnet-inventory.sh detail --with network_interfaces > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby subnet_inventory.rb snapshot)
ruby ruby/cli/subnet_inventory.rb snapshot
python3 python/sdk/subnet_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/subnet_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `network_interfaces` | `subnet` | サブネットにある ENI（EC2、RDS、Lambda、ALB、Fargate のタスクなど） | サブネットごとに `ec2:DescribeNetworkInterfaces` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `ec2:DescribeSubnets` と `ec2:DescribeRouteTables` を 1 回ずつ（ページ分）

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `ec2:DescribeSubnets`、`ec2:DescribeRouteTables`、`sts:GetCallerIdentity`
- 詳細取得: `ec2:DescribeNetworkInterfaces`

## 絞り込みの例

```bash
# 空き IP が少ないサブネット
jq -r 'select(.available_ip_address_count < 20) | [.subnet_id, .cidr_block, .available_ip_address_count] | @tsv' snapshot.jsonl

# パブリックサブネット
jq -r 'select(.is_public) | [.vpc_id, .subnet_id, .availability_zone] | @tsv' snapshot.jsonl
```

## わかっている制約

- `is_public` は、0.0.0.0/0 の行き先がインターネットゲートウェイ（`igw-`）かどうかだけで決める。IPv6 だけのルートは見ない
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
