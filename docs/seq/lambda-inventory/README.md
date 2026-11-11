# Lambda 関数の棚卸し

Lambda 関数を一覧にし、ランタイムとベース OS、設定、イベントソースマッピングを出す。ランタイムの更新計画や、どこから呼ばれているかの調査に使う。呼び出しを許可している相手（リソースベースポリシー）は詳細取得で出す。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/lambda-inventory.sh`](./shell/lambda-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/lambda_inventory.rb`](./ruby/sdk/lambda_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/lambda_inventory.rb`](./ruby/cli/lambda_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/lambda_inventory.py`](./python/sdk/lambda_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/lambda_inventory.py`](./python/cli/lambda_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

対応表は `tables/` が正本で、`../sync-common.sh` が各実装のディレクトリに写す。

- [`tables/runtimes.json`](./tables/runtimes.json): ランタイム識別子 → ベース OS の対応表

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/lambda-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "lambda_function")' snapshot.jsonl \
  | ./shell/lambda-inventory.sh detail --with policy > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby lambda_inventory.rb snapshot)
ruby ruby/cli/lambda_inventory.rb snapshot
python3 python/sdk/lambda_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/lambda_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `policy` | `lambda_function` | リソースベースポリシーで呼び出しを許可している相手（S3、EventBridge、API Gateway、関数 URL、他アカウントなど）。ポリシーが無ければ `[]` | 関数ごとに `lambda:GetPolicy` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `lambda:ListFunctions` と `lambda:ListEventSourceMappings` を 1 回ずつ（ページ分）。マッピングはリージョン全体をまとめて引き、関数 ARN で突き合わせる

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `lambda:ListFunctions`、`lambda:ListEventSourceMappings`、`sts:GetCallerIdentity`
- 詳細取得: `lambda:GetPolicy`

## 絞り込みの例

```bash
# Amazon Linux 2 以前で動いている関数
jq -r 'select(.base_os == "Amazon Linux 2" or .base_os == "Amazon Linux") | [.function_name, .runtime] | @tsv' snapshot.jsonl

# 対応表に無いランタイム
jq -r 'select(.base_os == "Unknown") | .runtime' snapshot.jsonl | sort -u

# 認証なしの関数 URL を持つ関数
./shell/lambda-inventory.sh detail --with policy < snapshot.jsonl | jq -r 'select(any(.details.policy[]?; .function_url_auth_type == "NONE")) | .function_name'
```

## わかっている制約

- `policy` は関数そのもの（$LATEST）のポリシーだけを見る。エイリアスやバージョンに付けた権限は出ない
- 呼び出し元のロールで許可している呼び出し（Step Functions など）は、Lambda 側に記録が無いので出ない
- 環境変数は名前だけを出す。値は出さない
- `runtimes.json` は手で更新する
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
