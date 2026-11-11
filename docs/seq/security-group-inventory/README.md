# セキュリティグループの棚卸し

セキュリティグループを一覧にし、ルールを 1 行ずつに展開して出す。どの ENI から使われているか、ほかのどの SG から参照されているかも出すので、使われていない SG や、だれにでも開いている SG を探すのに使う。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/security-group-inventory.sh`](./shell/security-group-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/security_group_inventory.rb`](./ruby/sdk/security_group_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/security_group_inventory.rb`](./ruby/cli/security_group_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/security_group_inventory.py`](./python/sdk/security_group_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/security_group_inventory.py`](./python/cli/security_group_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/security-group-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "security_group")' snapshot.jsonl \
  | ./shell/security-group-inventory.sh detail --with network_interfaces > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby security_group_inventory.rb snapshot)
ruby ruby/cli/security_group_inventory.rb snapshot
python3 python/sdk/security_group_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/security_group_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `network_interfaces` | `security_group` | SG を使っている ENI | SG ごとに `ec2:DescribeNetworkInterfaces` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `ec2:DescribeSecurityGroups` と `ec2:DescribeNetworkInterfaces` を 1 回ずつ（ページ分）。ENI はリージョン全体をまとめて引き、SG ごとに数える

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `ec2:DescribeSecurityGroups`、`ec2:DescribeNetworkInterfaces`、`sts:GetCallerIdentity`
- 詳細取得: `ec2:DescribeNetworkInterfaces`

## 絞り込みの例

```bash
# どこからも使われていない SG
jq -r 'select(.network_interface_count == 0 and .referenced_by == [] and .group_name != "default") | [.group_id, .group_name] | @tsv' snapshot.jsonl

# だれにでも開いている受信ルール
jq -r '.group_id as $g | .inbound_rules[] | select(.source == "0.0.0.0/0" or .source == "::/0") | [$g, .protocol, .from_port, .to_port] | @tsv' snapshot.jsonl
```

## わかっている制約

- `referenced_by` は同じアカウント・リージョンの SG だけを見る。ピアリング先の SG からの参照は出ない
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
