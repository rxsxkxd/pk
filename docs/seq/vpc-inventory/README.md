# VPC の棚卸し

VPC を一覧にし、VPC ごとにルートテーブル・インターネットゲートウェイ・NAT ゲートウェイ・VPC エンドポイント・ピアリングをまとめて出す。ネットワーク構成の全体を見渡すのに使う。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/vpc-inventory.sh`](./shell/vpc-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/vpc_inventory.rb`](./ruby/sdk/vpc_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/vpc_inventory.rb`](./ruby/cli/vpc_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/vpc_inventory.py`](./python/sdk/vpc_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/vpc_inventory.py`](./python/cli/vpc_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/vpc-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "vpc")' snapshot.jsonl \
  | ./shell/vpc-inventory.sh detail --with flow_logs > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby vpc_inventory.rb snapshot)
ruby ruby/cli/vpc_inventory.rb snapshot
python3 python/sdk/vpc_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/vpc_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `flow_logs` | `vpc` | VPC に設定したフローログ | VPC ごとに `ec2:DescribeFlowLogs` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `ec2:DescribeVpcs`・`DescribeRouteTables`・`DescribeInternetGateways`・`DescribeNatGateways`・`DescribeVpcEndpoints`・`DescribeVpcPeeringConnections`・`DescribeSubnets` を 1 回ずつ（ページ分）

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `ec2:DescribeVpcs`、`ec2:DescribeRouteTables`、`ec2:DescribeInternetGateways`、`ec2:DescribeNatGateways`、`ec2:DescribeVpcEndpoints`、`ec2:DescribeVpcPeeringConnections`、`ec2:DescribeSubnets`、`sts:GetCallerIdentity`
- 詳細取得: `ec2:DescribeFlowLogs`

## 絞り込みの例

```bash
# VPC ごとの CIDR と NAT ゲートウェイの数
jq -r '[.vpc_id, .cidr_block, (.nat_gateways | length)] | @tsv' snapshot.jsonl

# フローログを設定していない VPC を探す
./shell/vpc-inventory.sh detail --with flow_logs < snapshot.jsonl | jq -r 'select(.details.flow_logs == []) | .vpc_id'
```

## わかっている制約

- 削除済み（deleted）の NAT ゲートウェイとピアリングは除く
- Transit Gateway のアタッチメントは、ルートの target に ID が出るだけで、詳細は出さない
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
