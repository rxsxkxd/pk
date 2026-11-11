# SNS トピックの棚卸し

SNS トピックを一覧にし、トピックごとのサブスクリプションを出す。暗号化やアクセスポリシーは詳細取得で調べる。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/sns-inventory.sh`](./shell/sns-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/sns_inventory.rb`](./ruby/sdk/sns_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/sns_inventory.rb`](./ruby/cli/sns_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/sns_inventory.py`](./python/sdk/sns_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/sns_inventory.py`](./python/cli/sns_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/sns-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "sns_topic")' snapshot.jsonl \
  | ./shell/sns-inventory.sh detail --with attributes > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby sns_inventory.rb snapshot)
ruby ruby/cli/sns_inventory.rb snapshot
python3 python/sdk/sns_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/sns_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `attributes` | `sns_topic` | 暗号化・配信の状況・アクセスポリシーの要約 | トピックごとに `sns:GetTopicAttributes` を 1 回 |
| `tags` | `sns_topic` | タグ（キー → 値） | トピックごとに `sns:ListTagsForResource` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `sns:ListTopics` と `sns:ListSubscriptions` を 1 回ずつ（ページ分）。サブスクリプションはリージョン全体をまとめて引き、トピック ARN で突き合わせる

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `sns:ListTopics`、`sns:ListSubscriptions`、`sts:GetCallerIdentity`
- 詳細取得: `sns:GetTopicAttributes`、`sns:ListTagsForResource`

## 絞り込みの例

```bash
# サブスクリプションが無いトピック
jq -r 'select(.subscription_count == 0) | .topic_arn' snapshot.jsonl

# 暗号化していないトピック
./shell/sns-inventory.sh detail --with attributes < snapshot.jsonl | jq -r 'select(.details.attributes.kms_master_key_id == null) | .topic_name'
```

## わかっている制約

- メールアドレスと電話番号は個人の情報なので、`email` / `email-json` / `sms` のサブスクリプションの `endpoint` は `null` にする
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
