# SQS キューの棚卸し

SQS キューを一覧にする。一覧取得ではキューの URL と名前だけを取り、設定・溜まっているメッセージ数・デッドレターキュー・暗号化は詳細取得で調べる。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/sqs-inventory.sh`](./shell/sqs-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/sqs_inventory.rb`](./ruby/sdk/sqs_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/sqs_inventory.rb`](./ruby/cli/sqs_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/sqs_inventory.py`](./python/sdk/sqs_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/sqs_inventory.py`](./python/cli/sqs_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/sqs-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "sqs_queue")' snapshot.jsonl \
  | ./shell/sqs-inventory.sh detail --with attributes > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby sqs_inventory.rb snapshot)
ruby ruby/cli/sqs_inventory.rb snapshot
python3 python/sdk/sqs_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/sqs_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `attributes` | `sqs_queue` | キューの設定・溜まっているメッセージ数・デッドレターキュー・暗号化・アクセスポリシーの要約 | キューごとに `sqs:GetQueueAttributes` を 1 回 |
| `tags` | `sqs_queue` | タグ（キー → 値） | キューごとに `sqs:ListQueueTags` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `sqs:ListQueues` を 1 回（ページ分）

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `sqs:ListQueues`、`sts:GetCallerIdentity`
- 詳細取得: `sqs:GetQueueAttributes`、`sqs:ListQueueTags`

## 絞り込みの例

```bash
# メッセージが溜まっているキュー
./shell/sqs-inventory.sh detail --with attributes < snapshot.jsonl | jq -r 'select(.details.attributes.approximate_messages > 0) | [.queue_name, .details.attributes.approximate_messages] | @tsv'

# デッドレターキューを設定していないキュー
./shell/sqs-inventory.sh detail --with attributes < snapshot.jsonl | jq -r 'select(.details.attributes.dead_letter_target_arn == null) | .queue_name'
```

## わかっている制約

- メッセージ数はおおよその値で、取った時点のもの
- `max_receive_count` は、キューの設定に書かれたとおり数値か文字列で出る
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
