# API Gateway の API の棚卸し

API Gateway の REST API と、HTTP / WebSocket API を一覧にする。ステージとルート（行き先の統合）は詳細取得で、どちらの種類でも同じ項目名で出す。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/apigateway-inventory.sh`](./shell/apigateway-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/apigateway_inventory.rb`](./ruby/sdk/apigateway_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/apigateway_inventory.rb`](./ruby/cli/apigateway_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/apigateway_inventory.py`](./python/sdk/apigateway_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/apigateway_inventory.py`](./python/cli/apigateway_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/apigateway-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "apigateway_rest_api")' snapshot.jsonl \
  | ./shell/apigateway-inventory.sh detail --with stages > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby apigateway_inventory.rb snapshot)
ruby ruby/cli/apigateway_inventory.rb snapshot
python3 python/sdk/apigateway_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/apigateway_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `stages` | `apigateway_rest_api, apigateway_v2_api` | ステージ | API ごとに GetStages を 1 回 |
| `routes` | `apigateway_rest_api, apigateway_v2_api` | ルートと、その行き先（統合） | REST API は GetResources（メソッドを含める）を 1 回、HTTP / WebSocket API は GetIntegrations と GetRoutes を 1 回ずつ |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `apigateway:GET`（GetRestApis）と、apigatewayv2 の GetApis を 1 回ずつ（ページ分）

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `apigateway:GET`、`sts:GetCallerIdentity`
- 詳細取得: `apigateway:GET`

## 絞り込みの例

```bash
# API の種類と名前
jq -r '[.record_type, .api_id, .name] | @tsv' snapshot.jsonl

# WAF が付いていないステージ（REST API）
jq -c 'select(.record_type == "apigateway_rest_api")' snapshot.jsonl | ./shell/apigateway-inventory.sh detail --with stages | jq -r '.name as $n | .details.stages[]? | select(.web_acl_arn == null) | [$n, .stage_name] | @tsv'
```

## わかっている制約

- API Gateway の権限は、読み取りもすべて `apigateway:GET` で許可する
- カスタムドメインとそのマッピングは出さない
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
