# S3 バケットの棚卸し

S3 バケットを一覧にする。一覧取得ではバケット名・リージョン・作成日だけを取り、暗号化・公開設定・バージョニングなどは詳細取得で、絞り込んだバケットだけを調べる。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/s3-inventory.sh`](./shell/s3-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/s3_inventory.rb`](./ruby/sdk/s3_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/s3_inventory.rb`](./ruby/cli/s3_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/s3_inventory.py`](./python/sdk/s3_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/s3_inventory.py`](./python/cli/s3_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/s3-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "s3_bucket")' snapshot.jsonl \
  | ./shell/s3-inventory.sh detail --with security > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby s3_inventory.rb snapshot)
ruby ruby/cli/s3_inventory.rb snapshot
python3 python/sdk/s3_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/s3_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `security` | `s3_bucket` | 暗号化・パブリックアクセスブロック・バケットポリシーの公開状態・オブジェクトの所有者 | バケットごとに 4 回（GetBucketEncryption・GetPublicAccessBlock・GetBucketPolicyStatus・GetBucketOwnershipControls） |
| `management` | `s3_bucket` | バージョニング・ライフサイクル・アクセスログ | バケットごとに 3 回（GetBucketVersioning・GetBucketLifecycleConfiguration・GetBucketLogging） |
| `tags` | `s3_bucket` | タグ（キー → 値）。付いていなければ `{}` | バケットごとに `s3:GetBucketTagging` を 1 回 |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `s3:ListAllMyBuckets`（ListBuckets）を 1 回（ページ分）。リージョンをまたいで全バケットが返る

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `s3:ListAllMyBuckets`、`sts:GetCallerIdentity`
- 詳細取得: `s3:GetEncryptionConfiguration`、`s3:GetBucketPublicAccessBlock`、`s3:GetBucketPolicyStatus`、`s3:GetBucketOwnershipControls`、`s3:GetBucketVersioning`、`s3:GetLifecycleConfiguration`、`s3:GetBucketLogging`、`s3:GetBucketTagging`

## 絞り込みの例

```bash
# 東京リージョンのバケットの公開設定を調べる
jq -c 'select(.region == "ap-northeast-1")' snapshot.jsonl | ./shell/s3-inventory.sh detail --with security

# 詳細取得の結果から、パブリックアクセスブロックが無いバケット
jq -r 'select(.details.security.public_access_block == null) | .bucket_name' detail.jsonl
```

## わかっている制約

- 「設定が無い」ことを示すエラー（NoSuchBucketPolicy など）は、エラーではなく `null` や 0 として扱う
- 古い AWS CLI や SDK では、ListBuckets の応答にバケットのリージョンが入らず、`region` が `null` になる。そのときも詳細取得は動く（S3 の転送に任せる）
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
