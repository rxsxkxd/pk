# CloudFront ディストリビューションの棚卸し

CloudFront のディストリビューションを一覧にし、オリジン・既定のキャッシュ動作・証明書・WAF を出す。CloudFront はリージョンをまたぐサービスなので、`region` は `global` になる。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/cloudfront-inventory.sh`](./shell/cloudfront-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/cloudfront_inventory.rb`](./ruby/sdk/cloudfront_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/cloudfront_inventory.rb`](./ruby/cli/cloudfront_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/cloudfront_inventory.py`](./python/sdk/cloudfront_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/cloudfront_inventory.py`](./python/cli/cloudfront_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/cloudfront-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "cloudfront_distribution")' snapshot.jsonl \
  | ./shell/cloudfront-inventory.sh detail --with config > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby cloudfront_inventory.rb snapshot)
ruby ruby/cli/cloudfront_inventory.rb snapshot
python3 python/sdk/cloudfront_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/cloudfront_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `config` | `cloudfront_distribution` | 一覧に入っていない設定 | ディストリビューションごとに `cloudfront:GetDistributionConfig` を 1 回 |
| `tags` | `cloudfront_distribution` | タグ（キー → 値） | ディストリビューションごとに `cloudfront:ListTagsForResource` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `cloudfront:ListDistributions` を 1 回（ページ分）

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `cloudfront:ListDistributions`、`sts:GetCallerIdentity`
- 詳細取得: `cloudfront:GetDistributionConfig`、`cloudfront:ListTagsForResource`

## 絞り込みの例

```bash
# WAF を付けていないディストリビューション
jq -r 'select((.web_acl_id // "") == "") | [.distribution_id, .domain_name] | @tsv' snapshot.jsonl

# S3 オリジンで OAC を使っていないもの
jq -r '.distribution_id as $d | .origins[] | select(.origin_type == "s3" and (.origin_access_control_id // "") == "") | [$d, .domain_name] | @tsv' snapshot.jsonl
```

## わかっている制約

- キャッシュ動作は既定のものだけを出し、追加分は数だけを出す
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
