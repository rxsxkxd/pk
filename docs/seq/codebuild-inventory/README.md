# CodeBuild プロジェクトの棚卸し

CodeBuild のプロジェクトの定義を一覧にし、ビルド環境のイメージとベース OS、ソース、Webhook、VPC などを出す。直近のビルドの結果は詳細取得で調べる。

用語（一覧取得・詳細取得、シェル版・SDK 版・CLI 版など）と、全ツールに共通する仕組みは [`../README.md`](../README.md) を参照。結果データの項目は [`DATA.md`](./DATA.md) を参照。

## 実装

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル版 | [`shell/codebuild-inventory.sh`](./shell/codebuild-inventory.sh) | bash、AWS CLI v2、jq |
| Ruby SDK 版 | [`ruby/sdk/codebuild_inventory.rb`](./ruby/sdk/codebuild_inventory.rb) | Ruby 3.1 以上、[`ruby/sdk/Gemfile`](./ruby/sdk/Gemfile) の gem |
| Ruby CLI 版 | [`ruby/cli/codebuild_inventory.rb`](./ruby/cli/codebuild_inventory.rb) | Ruby 3.1 以上（標準ライブラリだけ）、AWS CLI v2 |
| Python SDK 版 | [`python/sdk/codebuild_inventory.py`](./python/sdk/codebuild_inventory.py) | Python 3.9 以上、boto3（[`python/sdk/requirements.txt`](./python/sdk/requirements.txt)） |
| Python CLI 版 | [`python/cli/codebuild_inventory.py`](./python/cli/codebuild_inventory.py) | Python 3.9 以上（標準ライブラリだけ）、AWS CLI v2 |

どの実装も、コマンドとオプションと出力は同じ。各実装のディレクトリは、それだけを持っていけば動く。

対応表は `tables/` が正本で、`../sync-common.sh` が各実装のディレクトリに写す。

- [`tables/codebuild-image-os.json`](./tables/codebuild-image-os.json): CodeBuild が提供するイメージ名 → ベース OS の対応表

## 使い方

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./shell/codebuild-inventory.sh snapshot > snapshot.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.record_type == "codebuild_project")' snapshot.jsonl \
  | ./shell/codebuild-inventory.sh detail --with last_build > detail.jsonl

# ほかの実装も同じ形で呼ぶ
(cd ruby/sdk && bundle install && bundle exec ruby codebuild_inventory.rb snapshot)
ruby ruby/cli/codebuild_inventory.rb snapshot
python3 python/sdk/codebuild_inventory.py snapshot   # boto3 が入った環境で
python3 python/cli/codebuild_inventory.py snapshot
```

## 一覧取得（snapshot）のオプション

なし。

## 詳細取得（detail）の種類

`--with` に種類をカンマ区切りで並べる。共通のオプション（`--interval`、`--max`）は [`../README.md`](../README.md) を参照。

| 種類 | 対象のレコード | 取るもの | 呼び出し |
|---|---|---|---|
| `last_build` | `codebuild_project` | 直近のビルド。ビルドが 1 度も無ければ `null` | プロジェクトごとに `codebuild:ListBuildsForProject`（1 ページ目だけ）と `codebuild:BatchGetBuilds` を 1 回ずつ |

## API の呼び出し

一覧取得で呼ぶ API は次のとおり。リソースごとの呼び出しはしない。

- `codebuild:ListProjects` を 1 回（ページ分）と、100 プロジェクトごとに `codebuild:BatchGetProjects`

どのレコードにも付ける `account_id` のために、`sts:GetCallerIdentity` を 1 回呼ぶ。

## 必要な IAM 権限

読み取りだけ。

- 一覧取得: `codebuild:ListProjects`、`codebuild:BatchGetProjects`、`sts:GetCallerIdentity`
- 詳細取得: `codebuild:ListBuildsForProject`、`codebuild:BatchGetBuilds`

## 絞り込みの例

```bash
# ビルド環境のベース OS ごとの数
jq -r '.base_os' snapshot.jsonl | sort | uniq -c

# 直近のビルドが失敗しているプロジェクト
./shell/codebuild-inventory.sh detail --with last_build < snapshot.jsonl | jq -r 'select(.details.last_build.status == "FAILED") | .project_name'
```

## わかっている制約

- 環境変数は名前も値も出さない
- CodePipeline や EventBridge から起動される設定は、プロジェクトの定義に残らないので出ない
- `codebuild-image-os.json` は手で更新する。Lambda コンピューティング用のイメージはまだ載せていないので `Unknown` になる
- 1 回の実行で見るのは 1 リージョンだけ（S3・CloudFront・WAF の CLOUDFRONT スコープを除く）
