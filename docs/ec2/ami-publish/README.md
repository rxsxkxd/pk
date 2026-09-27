# ami-publish — AMI 公開パイプライン

常時起動のリリース用 EC2 インスタンスから AMI を作成し、その AMI を使う起動テンプレートの新しいバージョンを用意するパイプライン一式。

- 設計: [開発計画: AMI 作成以降](../docs/ec2/ami-publish-development-plan.md)（決定事項 D1〜D10）
- スコープ: AMI の作成と起動テンプレートの用意まで。起動テンプレートを使った実際のインスタンスの構築（Auto Scaling グループを含む）は対象外

| ツール | 言語 | 動くタイミング | 実行する人 |
|---|---|---|---|
| 仕組みの生成ツール `cmd/generate-definitions` | Go | パイプラインの作成時 | 担当者（または CLI 経由でエージェント） |
| AMI 公開ツール `bin/ami_publish` | Ruby 3.4（AWS SDK for Ruby） | パイプラインの実行時（CodeBuild 上）。rollback は担当者が手元から実行 | パイプライン / 担当者 |

## ディレクトリ構成

```
config/ami_publish.yml                 環境ごとの設定値（Go と Ruby の両方が読む）
config/user_data/<環境>.sh             起動テンプレートの UserData
generated/                             仕組みの生成ツールの出力（コミットする。手で編集しない）
  codebuild/ami-publish-buildspec.yml                    CodeBuild の buildspec（全環境で共通）
  cloudformation/<環境>/launch-template-stack.yml        起動テンプレートのスタック
  cloudformation/<環境>/ami-publish-pipeline-stack.yml   AMI 公開パイプライン（CodePipeline・CodeBuild・IAM）
  cloudformation/<環境>/ssm-documents-stack.yml          SSM ドキュメント（ヘルスチェック）
cmd/generate-definitions/              仕組みの生成ツールの実行コマンド（配線だけ）
internal/definitions/                  生成する YAML の定義（Go）とテスト
bin/ami_publish                        AMI 公開ツールの実行コマンド
lib/ami_publish/                       AMI 公開ツール本体
  steps/                               ステップ（1 ファイル 1 ステップ）
  commands/                            サブコマンドごとのステップの組み合わせ
spec/                                  AMI 公開ツールのテスト（RSpec。AWS には接続しない）
```

## パイプラインの作成（担当者が行う）

最初の構築時と、仕組み（処理内容・権限・起動テンプレートの設定など）を変えるときだけ行う。

### 1. 仕組みのための構成元と設定の用意

`config/ami_publish.yml` と `internal/definitions/` を編集する。事前に AWS 側で用意するもの:

- CodeConnections の接続（このリポジトリへの接続。コンソールで承認まで済ませる）→ `pipeline.source_connection_arn`
- リリース用インスタンス（SSM Agent が動き、インスタンスプロファイルに `AmazonSSMManagedInstanceCore` があること）
- 起動テンプレートのスタックを初めて作るときに指定する既存の AMI

### 2. 仕組みのための定義の生成

```bash
go run ./cmd/generate-definitions
```

### 3. 生成物のレビュー

```bash
go run ./cmd/generate-definitions --check   # 定義と generated/ が一致しているか
go test ./...                               # 生成物の構造テスト
cfn-lint generated/cloudformation/*/*.yml   # CloudFormation テンプレートの検証
```

`generated/` の差分をプルリクエストでレビューし、承認を得る。

### 4. 仕組みのデプロイ（AWS CLI）

SSM ドキュメント → 起動テンプレート → AMI 公開パイプラインの順にデプロイする。各スタックとも `--no-execute-changeset` で変更セットを作り、内容を確認してから実行する。

```bash
ENV=staging

# SSM ドキュメント
aws cloudformation deploy --stack-name myapp-staging-ssm-documents \
  --template-file generated/cloudformation/$ENV/ssm-documents-stack.yml --no-execute-changeset

# 起動テンプレート（初回だけ AmiId / AppVersion を指定する。2 回目以降は指定しない＝現在の値を引き継ぐ）
aws cloudformation deploy --stack-name myapp-staging-launch-template \
  --template-file generated/cloudformation/$ENV/launch-template-stack.yml \
  --capabilities CAPABILITY_IAM --no-execute-changeset \
  --parameter-overrides AmiId=ami-xxxxxxxx AppVersion=v0.0.0

# AMI 公開パイプライン
aws cloudformation deploy --stack-name myapp-staging-ami-publish-pipeline \
  --template-file generated/cloudformation/$ENV/ami-publish-pipeline-stack.yml \
  --capabilities CAPABILITY_IAM --no-execute-changeset

# 変更内容を確認して実行
aws cloudformation describe-change-set --stack-name <スタック名> --change-set-name <表示された変更セット名>
aws cloudformation execute-change-set  --stack-name <スタック名> --change-set-name <変更セット名>
```

- 起動テンプレートのスタックのパラメータ `AmiId` / `AppVersion` は、2 回目以降はパイプラインが更新する。手動のデプロイで上書きしない。
- パイプラインは作成直後に 1 回自動で実行されることがある。変数 `VERSION` が未指定のため AMI 公開ツールが使い方の誤り（終了コード 2）で止まり、AWS には何も変更しない。

## パイプラインの実行

リリース用インスタンスにリリースバージョンを配置・起動し、動作を確認してから実行する。

```bash
aws codepipeline start-pipeline-execution --name myapp-staging-ami-publish \
  --variables name=VERSION,value=v1.2.3
```

処理の流れ（`lib/ami_publish/steps/`）:

| # | ステップ | 失敗時 |
|---|---|---|
| 1 | CreateImage: AMI を作成（インスタンスが再起動する）。同じ実行の AMI があれば再利用 | 失敗 |
| 2 | WaitImageAvailable: available まで待つ | AMI とスナップショットを削除 |
| 3 | WaitInstanceOnline: 再起動後に SSM Agent が接続するまで待つ | AMI とスナップショットを削除 |
| 4 | HealthCheck: SSM ドキュメントでアプリの応答を確認 | AMI とスナップショットを削除 |
| 5 | UpdateLaunchTemplateStack: 変更セット → 差分の検証（起動テンプレートの変更以外があれば中止）→ 実行 | AMI は残す（同じ実行の再実行で再利用） |
| 6 | PublishOutputs: AMI に `Status=published`、`AMI_ID` / `LAUNCH_TEMPLATE_VERSION` を出力 | — |

どのステップで失敗しても、起動テンプレートは更新されない。

## ロールバック（担当者が手元から実行する）

```bash
bundle exec ruby bin/ami_publish rollback --environment staging --to-version v1.2.2 --dry-run  # 差分の確認
bundle exec ruby bin/ami_publish rollback --environment staging --to-version v1.2.2
```

タグ `AppVersion=v1.2.2`・`Status=published` の AMI を探し、通常のリリースと同じ変更セットの検証を通して起動テンプレートのスタックを更新する。

## 手元での確認

```bash
bundle exec ruby bin/ami_publish plan --environment staging --version v1.2.3  # AWS に書き込まずに流れを確認
bundle exec rspec
bundle exec rubocop
```

## 検証状況

| 項目 | 結果 |
|---|---|
| Go: `go vet` / `gofmt` / `go test` / `--check` | 通過 |
| Ruby: `rspec`（41 件、AWS には接続しない）/ `rubocop` | 通過。テストが失敗を検出できることも、実装を一時的に壊して確認済み |
| `cfn-lint`（生成した CloudFormation テンプレート） | 指摘なし |
| buildspec の手順を Linux（`ruby:3.4`、x86_64）で実行 | install 成功。`VERSION` 未指定で終了コード 2、認証情報なしで終了コード 3、出力ファイルは作られない |
| CodeBuild 標準イメージの Ruby 3.4 | `aws/codebuild/standard:7.0` が Ruby 3.4 を提供（[公式のイメージ定義](https://github.com/aws/aws-codebuild-docker-images/blob/master/ubuntu/standard/7.0/runtimes.yml)） |

- `Gemfile.lock` には Linux のプラットフォーム（`x86_64-linux`・`aarch64-linux`）を含めている。macOS だけで `bundle lock` し直すと CodeBuild の `bundle install` が失敗するので、プラットフォームを消さない
- ネイティブ拡張（`bigdecimal`）のビルドに C コンパイラが必要。CodeBuild の標準イメージには入っている

## 未実施（AWS 環境が必要）

- `config/ami_publish.yml` のダミーの値（インスタンス ID、接続 ARN、セキュリティグループ、シークレット）を実際の値に置き換える
- 開発アカウントへのデプロイと、パイプラインの実行（開発計画の M6 結合検証・障害試験）
