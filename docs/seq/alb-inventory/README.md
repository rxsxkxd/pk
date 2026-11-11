# ロードバランサー（ALB）とターゲットグループの棚卸し

Elastic Load Balancing v2 のロードバランサーとターゲットグループを一覧にする。ALB のほか、同じ API で返る NLB・GWLB も含めて出し、`type` で見分ける。リスナーと振り分けルール、属性、ターゲットのヘルスは詳細取得で調べる。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/alb-inventory.sh`](./shell/alb-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/alb_inventory.rb`](./ruby/sdk/alb_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/alb_inventory.rb`](./ruby/cli/alb_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/alb_inventory.py`](./python/sdk/alb_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/alb_inventory.py`](./python/cli/alb_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/alb-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "elbv2_load_balancer")' snapshot.jsonl \
  | ./shell/alb-inventory.sh detail --with listeners > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby alb_inventory.rb snapshot)
ruby ruby/cli/alb_inventory.rb snapshot
python3 python/sdk/alb_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/alb_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `listeners` | `elbv2_load_balancer` | リスナーと、その振り分けルール | ロードバランサーごとに DescribeListeners を 1 回と、リスナーごとに DescribeRules を 1 回 |
| `attributes` | `elbv2_load_balancer` | ロードバランサーの属性（削除保護・アクセスログ・アイドルタイムアウトなど）をキー → 値で | ロードバランサーごとに DescribeLoadBalancerAttributes を 1 回 |
| `target_health` | `elbv2_target_group` | 登録されたターゲットとそのヘルス | ターゲットグループごとに DescribeTargetHealth を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `elasticloadbalancing:DescribeLoadBalancers` と `DescribeTargetGroups` を 1 回ずつ（ページ分）
- `elasticloadbalancing:DescribeTags` を 20 リソースごとに 1 回

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `elasticloadbalancing:DescribeLoadBalancers`、`elasticloadbalancing:DescribeTargetGroups`、`elasticloadbalancing:DescribeTags`、`sts:GetCallerIdentity`
- 詳細取得: `elasticloadbalancing:DescribeListeners`、`elasticloadbalancing:DescribeRules`、`elasticloadbalancing:DescribeLoadBalancerAttributes`、`elasticloadbalancing:DescribeTargetHealth`

## 絞り込みの例

```bash
# インターネット向けの ALB
jq -r 'select(.record_type == "elbv2_load_balancer" and .type == "application" and .scheme == "internet-facing") | .load_balancer_name' snapshot.jsonl

# どのロードバランサーにもつながっていないターゲットグループ
jq -r 'select(.record_type == "elbv2_target_group" and .load_balancer_arns == []) | .target_group_name' snapshot.jsonl
```

## わかっている制約

- Classic Load Balancer（ELB v1）は出さない
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
