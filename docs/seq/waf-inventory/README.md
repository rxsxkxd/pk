# WAF（wafv2）の Web ACL の棚卸し

WAF の Web ACL を一覧にする。ALB・API Gateway 向けの REGIONAL スコープと、CloudFront 向けの CLOUDFRONT スコープ（us-east-1 にある）の両方を見る。ルール・関連付け先・ログの設定は詳細取得で調べる。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/waf-inventory.sh`](./shell/waf-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/waf_inventory.rb`](./ruby/sdk/waf_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/waf_inventory.rb`](./ruby/cli/waf_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/waf_inventory.py`](./python/sdk/waf_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/waf_inventory.py`](./python/cli/waf_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/waf-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "wafv2_web_acl")' snapshot.jsonl \
  | ./shell/waf-inventory.sh detail --with rules > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby waf_inventory.rb snapshot)
ruby ruby/cli/waf_inventory.rb snapshot
python3 python/sdk/waf_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/waf_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

| オプション | 内容 |
|---|---|
| `--scope REGIONAL|CLOUDFRONT` | 見るスコープ。何回でも指定できる。指定しなければ両方 |

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `rules` | `wafv2_web_acl` | 既定のアクションとルールの一覧 | Web ACL ごとに `wafv2:GetWebACL` を 1 回 |
| `resources` | `wafv2_web_acl` | Web ACL を関連付けている先。`{resource_type, resource_arn}` | REGIONAL は種類（ALB・API Gateway・AppSync・Cognito）ごとに `wafv2:ListResourcesForWebACL` を 1 回、CLOUDFRONT は `cloudfront:ListDistributionsByWebACLId` を 1 回 |
| `logging` | `wafv2_web_acl` | ログの出力先 `{log_destinations}`。設定していなければ `null` | Web ACL ごとに `wafv2:GetLoggingConfiguration` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- スコープごとに `wafv2:ListWebACLs`。NextMarker を自分でたどる。CLOUDFRONT スコープは us-east-1 で呼ぶ

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `wafv2:ListWebACLs`、`sts:GetCallerIdentity`
- 詳細取得: `wafv2:GetWebACL`、`wafv2:ListResourcesForWebACL`、`wafv2:GetLoggingConfiguration`、`cloudfront:ListDistributionsByWebACLId`

## 絞り込みの例

```bash
# どこにも関連付けていない Web ACL
./shell/waf-inventory.sh detail --with resources < snapshot.jsonl | jq -r 'select(.details.resources == []) | [.scope, .name] | @tsv'

# 使っているマネージドルールグループ
./shell/waf-inventory.sh detail --with rules < snapshot.jsonl | jq -r '.details.rules.rules[]?.managed_rule_group // empty' | sort | uniq -c
```

## わかっている制約

- `resources` の REGIONAL は ALB・API Gateway・AppSync・Cognito だけを見る（App Runner と Verified Access は見ない）
- WAF Classic（v1）は出さない
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
