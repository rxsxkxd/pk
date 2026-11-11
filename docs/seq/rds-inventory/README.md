# RDS の DB インスタンスと DB クラスターの棚卸し

RDS（Aurora を含む）の DB インスタンスと DB クラスターを一覧にする。エンジンの版、保守の予定、暗号化・公開・バックアップの設定を調べるのに使う。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/rds-inventory.sh`](./shell/rds-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/rds_inventory.rb`](./ruby/sdk/rds_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/rds_inventory.rb`](./ruby/cli/rds_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/rds_inventory.py`](./python/sdk/rds_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/rds_inventory.py`](./python/cli/rds_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/rds-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "rds_db_instance")' snapshot.jsonl \
  | ./shell/rds-inventory.sh detail --with parameters > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby rds_inventory.rb snapshot)
ruby ruby/cli/rds_inventory.rb snapshot
python3 python/sdk/rds_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/rds_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `parameters` | `rds_db_instance, rds_db_cluster` | パラメータグループで既定から変えた値（Source=user） | パラメータグループごとに `rds:DescribeDBParameters` または `rds:DescribeDBClusterParameters` を 1 回（同じものは使い回す） |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `rds:DescribeDBInstances` と `rds:DescribeDBClusters` を 1 回ずつ（ページ分）
- `rds:DescribePendingMaintenanceActions` を 1 回（ページ分）。失敗したときは各レコードの `errors` に残して続ける

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `rds:DescribeDBInstances`、`rds:DescribeDBClusters`、`rds:DescribePendingMaintenanceActions`、`sts:GetCallerIdentity`
- 詳細取得: `rds:DescribeDBParameters`、`rds:DescribeDBClusterParameters`

## 絞り込みの例

```bash
# エンジンと版の一覧
jq -r '[.record_type, (.db_instance_identifier // .db_cluster_identifier), .engine, .engine_version] | @tsv' snapshot.jsonl

# 保留中のメンテナンスがあるもの
jq -c 'select(.pending_maintenance != []) | {id: (.db_instance_identifier // .db_cluster_identifier), pending_maintenance}' snapshot.jsonl

# パブリックに公開している DB インスタンス
jq -r 'select(.publicly_accessible == true) | .db_instance_identifier' snapshot.jsonl
```

## わかっている制約

- DescribeDBInstances / DescribeDBClusters は、DocumentDB や Neptune のものも返す。`engine` で見分ける
- Aurora の DB インスタンスは `rds_db_instance` と、所属する `rds_db_cluster` の両方に出る
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
