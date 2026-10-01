# ami-publish — AMI 公開パイプライン

常時起動のリリース用 EC2 インスタンスから AMI を作成し、その AMI を使う起動テンプレートの新しいバージョンを用意するパイプライン一式。

リリースの流れ（前段: 作成元のインスタンスでのテスト → **中段: AMI と起動テンプレートの用意** → 後段: 起動テンプレートを使ったインスタンスの構築）のうち、中段を担当する（フェーズ 1。後段がフェーズ 2、前段がフェーズ 3）。全体像と前段・後段のフォルダは [`../README.md`](../README.md#全体像) を参照。

- 設計: [開発計画: AMI 作成以降](../ami-publish-development-plan.md)（決定事項 D1〜D10）
- スコープ: AMI の作成と起動テンプレートの用意まで。起動テンプレートを使った実際のインスタンスの構築（Auto Scaling グループを含む）は対象外

| ツール | 言語 | 動くタイミング | 実行する人 |
|---|---|---|---|
| 仕組みの生成ツール `cmd/generate-definitions` | Go | パイプラインの作成時 | 担当者（または CLI 経由でエージェント） |
| AMI 公開ツール `bin/ami_publish` | Ruby 3.4（AWS SDK for Ruby） | パイプラインの実行時（CodeBuild 上）。rollback は担当者が手元から実行 | パイプライン / 担当者 |

## ディレクトリ構成

```
config/ami_publish.yml                 環境ごとの設定値（Go と Ruby の両方が読む）。リソースの名前は書かない（下記）
generated/                             仕組みの生成ツールの出力（コミットする。手で編集しない）
  codebuild/ami-publish-buildspec.yml                    CodeBuild の buildspec（全環境で共通）
  cloudformation/<環境>/launch-template-stack.yml        起動テンプレートのスタック
  cloudformation/<環境>/ami-publish-pipeline-stack.yml   AMI 公開パイプライン（CodePipeline・CodeBuild・IAM）
  cloudformation/<環境>/health-check-stack.yml           再起動後のヘルスチェック（SSM ドキュメント）
  cloudformation/<環境>/release-instance-stack.yml       リリース用インスタンスの IAM ロール・インスタンスプロファイル（deploy/<環境>.sh には含めない。個別にデプロイする）
  deploy/<環境>.sh                                       3 つのスタックをデプロイ（up）・削除（down）する AWS CLI の呼び出しを並べたシェルスクリプト
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

- このリポジトリの取得元（`pipeline.source_type`）:
  - GitHub（既定）: CodeConnections の接続（コンソールで承認まで済ませる）→ `pipeline.source_connection_arn`、`pipeline.source_repository_id`
  - CodeCommit: `pipeline.source_type: codecommit` とリポジトリ名（`pipeline.source_repository_name`）。接続は不要
- リリース用インスタンス（SSM Agent がインストール済みで自動起動が有効なこと。**インスタンスプロファイルは付けない**。パイプラインが、リリース用インスタンスの IAM ロールのスタックのインスタンスプロファイルを、ヘルスチェックの区間だけ紐付ける。[リリース用インスタンスの IAM ロール](../ami-publish-release-instance-iam.md)）
- ヘルスチェックに Basic 認証が必要な場合: 「ユーザー名:パスワード」を置いた SSM Parameter Store の SecureString（`health_check.basic_auth_parameter_name`）。CloudFormation では SecureString を作れないため、担当者が作成する:

  ```bash
  aws ssm put-parameter --type SecureString --name /myapp/staging/health-check/basic-auth --value 'ユーザー名:パスワード'
  ```

  ヘルスチェックのスタックをデプロイした後、出力 `BasicAuthParameterReadPolicyArn` の管理ポリシーを、リリース用インスタンスの IAM ロールにアタッチする（`aws iam attach-role-policy --role-name <ロール名> --policy-arn <ARN>`）。リリース用インスタンスには AWS CLI が必要。パラメーターは `--key-id` を指定せず、既定の `aws/ssm` キーで暗号化する（カスタマー管理の KMS キーには対応しない。パイプラインは開始時に確かめて止まる）

### 2. 仕組みのための定義の生成

```bash
go run ./cmd/generate-definitions
```

スタック・パイプライン・ロググループ・SSM ドキュメントなどの名前は、`application_name` と環境名から自動で決まる（命名規則は `internal/definitions/naming.go`。Ruby 側は `lib/ami_publish/configuration.rb` に同じ規則を実装）。生成時に一覧が表示される。

```
環境 staging の名前（自動）:
  myapp-staging-ami-publish-pipeline       AMI 公開パイプラインのスタック
  myapp-staging-ami-publish                CodePipeline のパイプライン
  myapp-staging-ami-publish                CodeBuild プロジェクト
  /myapp/staging/ami-publish               CloudWatch Logs のロググループ
  myapp-staging-launch-template            起動テンプレートのスタック
  myapp-staging                            起動テンプレート
  myapp-staging-health-check               ヘルスチェックのスタック
  myapp-staging-health-check               ヘルスチェックの SSM ドキュメント
```

### 3. 生成物のレビュー

```bash
go run ./cmd/generate-definitions --check   # 定義と generated/ が一致しているか
go test ./...                               # 生成物の構造テスト
cfn-lint generated/cloudformation/*/*.yml   # CloudFormation テンプレートの検証
```

`generated/` の差分をプルリクエストでレビューし、承認を得る。

### 4. 仕組みのデプロイ（AWS CLI）

仕組みの生成ツールが出力するデプロイ用シェルスクリプト `generated/deploy/<環境>.sh` を `up` で実行する。中身は、命名規則どおりのスタック名とテンプレートのパスを入れた AWS CLI の呼び出しを、依存関係の順（ヘルスチェック → 起動テンプレート → AMI 公開パイプライン）に並べただけのもの。スタック名を手で書かないので、AMI 公開ツールが探す名前とずれない。

**前提: リリース用インスタンスの IAM ロールのスタック（`<application_name>-<環境>-release-instance`）を先にデプロイしておく。** AMI 公開パイプラインのスタックがその Export（ロールとインスタンスプロファイルの ARN）を参照する。このスタックは `up` / `down` に含めない（手順は [リリース用インスタンスの IAM ロール](../ami-publish-release-instance-iam.md#2-リリース用インスタンスの-iam-ロールのスタックをデプロイする)）。

```bash
bash generated/deploy/staging.sh up
```

各スタックとも変更セットを作るだけで、反映はしない（`--no-execute-changeset`）。表示された変更セットの内容を確認してから、依存関係の順に反映する。

**初回だけ `up` を 2 回実行する**: AMI 公開パイプラインのスタックは、ヘルスチェックと起動テンプレートのスタックの Export（スタック名、SSM ドキュメント名）を参照している。1 回目の `up` では、この 2 つが反映される前なので、パイプラインの変更セットの作成がエラーで止まる。2 つを反映してからもう一度 `up` を実行すると、反映済みの 2 つは「変更なし」で通過し、パイプラインの変更セットが作られる。

```bash
aws cloudformation describe-change-set --stack-name <スタック名> --change-set-name <表示された変更セット名>
aws cloudformation execute-change-set  --stack-name <スタック名> --change-set-name <変更セット名>
```

- 起動テンプレートのスタックのパラメータ `AmiId` / `AppVersion` はパイプラインが更新する。手動のデプロイで指定しない（初回は空のまま作られ、起動テンプレートに AMI が入っていない状態になる。AMI が入るまでは、この起動テンプレートでインスタンスを起動するには AMI の指定が必要）。
- パイプラインは作成直後に 1 回自動で実行されることがある。変数 `VERSION` が未指定のため AMI 公開ツールが使い方の誤り（終了コード 2）で止まり、AWS には何も変更しない。

### 仕組みの撤去

`down` で、依存関係の逆順（AMI 公開パイプライン → 起動テンプレート → ヘルスチェック）にスタックを削除する。パイプラインのアーティファクト用の S3 バケットは、削除の前に中身を空にする。

```bash
bash generated/deploy/staging.sh down
```

- 確認の問い合わせはない。実行するとすぐに削除が始まる
- AMI とスナップショットはスタックのリソースではないため残る（必要なら [確認手順書の後片付け](../ami-publish-environment-verification.md#7-後片付けと記録) の手順で削除する）
- 起動テンプレートのスタックを削除すると起動テンプレートも消える。起動テンプレートから起動済みのインスタンスには影響しない
- リリース用インスタンスの IAM ロールのスタックは削除しない。不要なら `down` の後に、紐付けが残っていないことを確かめてから個別に削除する

## パイプラインの実行

リリース用インスタンスにリリースバージョンを配置・起動し、動作を確認してから実行する。

```bash
aws codepipeline start-pipeline-execution --name myapp-staging-ami-publish \
  --variables name=VERSION,value=v1.2.3
```

**ヘルスチェックの省略**: 既定ではヘルスチェック（再起動後にアプリが自動で起動して応答するかの確認）を行う。省略する場合は、パイプライン変数 `HEALTH_CHECK` に `false` を指定する（手元の `run` / `plan` では `--health-check false`）。

```bash
aws codepipeline start-pipeline-execution --name myapp-staging-ami-publish \
  --variables name=VERSION,value=v1.2.3 name=HEALTH_CHECK,value=false
```

省略すると、ヘルスチェックのためだけに行っている処理もまとめて行わない（SSM に依存しなくなる）。

| 処理 | 既定（`HEALTH_CHECK=true`） | 省略（`HEALTH_CHECK=false`） |
|---|---|---|
| 0 インスタンスプロファイルの紐付けの確認 | 行う | 行わない |
| 0b ロールの許可の確認 | 行う | 行わない |
| 1a・4a インスタンスプロファイルの紐付けと解除 | 行う | 行わない |
| 2a 停止中のインスタンスの起動 | 行う | 行わない（停止したまま AMI を作って終わる） |
| 3 再起動後の SSM の接続待ち・4 ヘルスチェック | 行う | 行わない |
| AMI のタグ `HealthCheck` | `passed` | `skipped` |

省略した AMI は、「その AMI から起動してアプリが動くか」を確かめていない。タグ `HealthCheck=skipped` で区別できる。

処理の流れ（`lib/ami_publish/steps/`）:

| # | ステップ | 失敗時 |
|---|---|---|
| 0 | CheckInstanceState: リリース用インスタンスの状態を確認し、起動中か停止中かを記録（起動処理中・停止処理中なら落ち着くまで待つ）。あわせてインスタンスプロファイルの紐付けが「なし」か「リリース用インスタンスの IAM ロールのスタックのプロファイル」（前回の異常終了の残り）であることを確認する。SSM の管理対象かは、紐付け前は判定できないので確認しない | 別のプロファイルが付いていれば失敗（AMI を作らず、何も変更しない） |
| 0b | CheckReleaseInstancePermissions: リリース用インスタンスの IAM ロールのスタックのロール（パイプラインのスタックの出力 `ReleaseInstanceRoleArn`）に必要な許可（[一覧](../ami-publish-release-instance-iam.md)）があるかを、IAM のポリシーシミュレーターで判定する。紐付け前・停止中でも判定できる | A・C の不足は失敗（不足している許可を一覧にする。AMI を作らず、何も変更しない）。B（CloudWatch Logs への出力）の不足は警告を出して先に進む。Basic 認証のパラメーターが既定の `aws/ssm` キーの SecureString でなければ失敗 |
| 1a | WithReleaseInstanceProfile: **AMI の作成の直前に**、リリース用インスタンスの IAM ロールのスタックのインスタンスプロファイルを紐付ける（すでに付いていればそのまま使う）。1〜4 はこの紐付けの区間の中で動く（[設計](../ami-publish-health-check-role-association-flow.md)） | 失敗（AMI を作らない。途中までの紐付けは解除する） |
| 1 | CreateImage: AMI を作成（起動中ならインスタンスが再起動する。停止中なら再起動しない）。同じ実行の AMI があれば再利用。AMI 名は `<application_name>_<バージョン>_<日時>`、Name タグは `<ami.name_tag_prefix>_<バージョン>_<日時>`（どちらも環境は含めない。接頭辞の省略時は `<バージョン>_<日時>`。同じアカウントで環境ごとに AMI 名を分ける必要があれば、`application_name` に環境を含める） | 失敗 |
| 2 | WaitImageAvailable: available まで待つ | AMI とスナップショットを削除 |
| 2a | StartInstanceIfStopped: **開始時に停止中だった場合だけ**、確認のためにインスタンスを起動する（停止には戻さない） | AMI とスナップショットを削除 |
| 3 | WaitInstanceOnline: 再起動（または起動）後に SSM Agent が接続するまで待つ | AMI とスナップショットを削除 |
| 4 | HealthCheck: SSM ドキュメントでアプリの応答を確認 | AMI とスナップショットを削除 |
| 4a | WithReleaseInstanceProfile: 紐付けを解除する。**1〜4 のどこで失敗しても必ず解除する**（CodeBuild のタイムアウト・強制終了の場合だけは解除されず、次の実行で解除される） | 成功後の解除の失敗は、AMI を残して失敗（同じ実行の再試行で再利用）。失敗後の解除の失敗は、手で外すコマンドをログに出す |
| 5 | UpdateLaunchTemplateStack: 変更セット → 差分の検証（起動テンプレートの変更以外があれば中止）→ 実行 | AMI は残す（同じ実行の再実行で再利用） |
| 6 | PublishOutputs: AMI に `Status=published`、`AMI_ID` / `LAUNCH_TEMPLATE_VERSION` を出力 | — |

どのステップで失敗しても、起動テンプレートは更新されない。

開始時に停止中だったリリース用インスタンスは、パイプラインが終わった後も起動したまま残る（成功・失敗とも）。停止に戻す場合は、パイプラインの外で行う。停止中のインスタンスから作る AMI は、ディスクへの書き込みがない状態で作られ、その後の起動で AMI と同じディスクの状態から OS を起動して確認する。

### 進捗ログ

時間のかかる処理は、待っている間も `timeouts.progress_log_interval_seconds`（既定 60 秒）ごとに進捗をログに出す。止まって見えるときは、最後の進捗ログでどこを何を待っているかがわかる。

| どこで | 進捗ログ | 主な項目 |
|---|---|---|
| ステップ 0 インスタンスの状態の確定 | `{"event":"waiting","description":"リリース用インスタンスの状態が落ち着くまで",...}` | 経過秒数、インスタンスの状態（`pending` / `stopping`） |
| ステップ 0 SSM の接続確認（起動中の場合） | `{"event":"waiting","description":"SSM Agent の接続（AMI 作成前の確認）",...}` | 経過秒数、`ping_status`（「SSM に未登録」なら SSM の管理対象になっていない） |
| ステップ 2a インスタンスの起動（停止中だった場合） | `{"event":"waiting","description":"リリース用インスタンスの起動",...}` | 経過秒数、インスタンスの状態 |
| ステップ 2 AMI の作成 | `{"event":"waiting","description":"AMI の作成（スナップショットの取得）",...}` | 経過秒数、AMI の状態、スナップショットの進み具合（例: `snap-0123 45%`） |
| ステップ 3 SSM Agent の接続待ち | `{"event":"waiting","description":"再起動後の SSM Agent の接続",...}` | 経過秒数、`ping_status`（`ConnectionLost` など）、最後に接続した時刻 |
| ステップ 4 ヘルスチェック | `{"event":"waiting","description":"ヘルスチェック",...}` | 経過秒数、コマンドの状態 |
| ステップ 5 変更セットの作成・スタックの更新 | `{"event":"waiting","description":"起動テンプレートのスタックの更新",...}` など | 経過秒数、変更セット・スタックの状態 |

## ロールバック（担当者が手元から実行する）

```bash
bundle exec ruby bin/ami_publish rollback --environment staging --to-version v1.2.2 --dry-run  # 差分の確認
bundle exec ruby bin/ami_publish rollback --environment staging --to-version v1.2.2
```

タグ `AppVersion=v1.2.2`・`Status=published` の AMI を探し、通常のリリースと同じ変更セットの検証を通して起動テンプレートのスタックを更新する。

## 手元での確認

AWS に触れないものは完全にローカルで動く。AMI 公開ツールの本体（`plan` / `run` / `rollback`）は手元から実行できるが、AWS の認証情報と接続が必要。

| 対象 | AWS | 備考 |
|---|---|---|
| 仕組みの生成ツール `go run ./cmd/generate-definitions` / `--check` / `go test ./...` | 不要 | ネットワークも不要（Go のライブラリを取得済みなら） |
| AMI 公開ツールのテスト `bundle exec rspec` / `bundle exec rubocop` | 不要 | AWS SDK のスタブを使い、AWS に接続しない |
| `cfn-lint generated/cloudformation/*/*.yml` | 不要 | cfn-lint は別途インストールする（`pip install cfn-lint`） |
| `bin/ami_publish plan` | **必要** | dry-run でも読み取り API（`DescribeImages`、`DescribeStacks`）を呼ぶ。書き込みはしない |
| `bin/ami_publish rollback` | **必要** | 担当者が手元から実行する前提（決定事項 D7）。`--dry-run` で差分だけを確認できる |
| `bin/ami_publish run` | **必要** | 実際に AMI を作成し、リリース用インスタンスが再起動する。通常はパイプラインから実行し、手元からは検証用 |
| buildspec の手順 | 内容による | Docker（`ruby:3.4`、x86_64）で再現できる。下記参照 |

### AWS を使わない確認

```bash
go run ./cmd/generate-definitions --check
go test ./...
bundle exec rspec
bundle exec rubocop
```

### AWS を使う実行

認証情報はプロファイルなどで渡す。

```bash
AWS_PROFILE=<プロファイル名> bundle exec ruby bin/ami_publish plan --environment staging --version v1.2.3
AWS_PROFILE=<プロファイル名> bundle exec ruby bin/ami_publish rollback --environment staging --to-version v1.2.2 --dry-run
```

- 実行するユーザー（またはロール）には、CodeBuild のサービスロールと同等の権限が必要（AMI の作成・参照・削除、SSM でのヘルスチェックの実行、起動テンプレートのスタックの変更セット操作、スタック用サービスロールの `iam:PassRole` など。`generated/cloudformation/<環境>/ami-publish-pipeline-stack.yml` の `CodeBuildServiceRole` を参照）
- 起動テンプレートのスタックと AMI 公開パイプラインのスタックがデプロイ済みである必要がある（起動テンプレートのスタック名などを、パイプラインのスタックの出力から取得するため）

### buildspec の手順を Docker で再現する

CodeBuild と同じ x86_64 の Linux で、buildspec の install と build のコマンドを流す。C コンパイラが必要なため、`ruby:3.4-slim` ではなく `ruby:3.4` を使う。

`ruby:3.4` には rbenv が入っていないため、buildspec の `rbenv local` は実行されず（`if` で飛ばす）、コンテナの Ruby 3.4 がそのまま使われる。

```bash
tar --exclude=./vendor --exclude=./.bundle -cf - . | docker run --rm -i --platform linux/amd64 \
  -e AMI_PUBLISH_ENVIRONMENT=staging -e VERIFIED=manual -e PIPELINE_EXECUTION_ID=exec-local \
  ruby:3.4 bash -c '
    mkdir /work && cd /work && tar -xf -
    ruby --version
    bundle config set --local deployment true && bundle config set --local without "development test" && bundle install
    bundle exec ruby bin/ami_publish run --environment "$AMI_PUBLISH_ENVIRONMENT" --version v1.2.3 \
      --verified "$VERIFIED" --pipeline-execution-id "$PIPELINE_EXECUTION_ID" --output-env-file ami_publish_outputs.env
    echo "exit=$?"'
```

認証情報を渡さなければ、AWS に接続する前に終了コード 3 で止まる（install の成否と、ツールの起動・エラー処理を確認できる）。

### AWS を模擬する方法について

LocalStack などで EC2 や SSM を模擬する方法もあるが、AMI の作成や SSM のコマンド実行は再現性が低いため使わない。AWS を使わない確認はスタブのテストで行い、実際の動作は開発アカウントで確認する。

## 検証状況

| 項目 | 結果 |
|---|---|
| Go: `go vet` / `gofmt` / `go test` / `--check` | 通過 |
| Ruby: `rspec`（87 件、AWS には接続しない）/ `rubocop` | 通過。テストが失敗を検出できることも、実装を一時的に壊して確認済み |
| `cfn-lint`（生成した CloudFormation テンプレート） | 指摘なし |
| buildspec の手順を Linux（`ruby:3.4`、x86_64）で実行 | install 成功。`VERSION` 未指定で終了コード 2、認証情報なしで終了コード 3、出力ファイルは作られない |
| CodeBuild 標準イメージ | `aws/codebuild/standard:8.0`（Ubuntu 24.04。Ubuntu 系の最新）を使う。rbenv（`/usr/local/rbenv`）と Ruby 3.4.10 が入っている（[公式のイメージ定義](https://github.com/aws/aws-codebuild-docker-images/blob/master/ubuntu/standard/8.0/Dockerfile)）。buildspec は `runtime-versions` を使わず、`rbenv local 3.4.10` でイメージの Ruby を選ぶ（Ruby のビルドは行わない）。手元の `.ruby-version`（3.4.11）とはパッチバージョンが異なるが、deployment モードの `bundle install` が問題なく通ることを確認済み。イメージと Ruby のバージョンは頻繁に変えないため、設定値ファイルではなく `internal/definitions/ami_publish_buildspec.go` の定数 `codeBuildImage` / `codeBuildRubyVersion` で固定している。イメージの更新で 3.4.10 がなくなったら `codeBuildRubyVersion` を上げる |

- `Gemfile.lock` には Linux のプラットフォーム（`x86_64-linux`・`aarch64-linux`）を含めている。macOS だけで `bundle lock` し直すと CodeBuild の `bundle install` が失敗するので、プラットフォームを消さない
- ネイティブ拡張（`bigdecimal`）のビルドに C コンパイラが必要。CodeBuild の標準イメージには入っている
- 手元では gem をリポジトリ内（`vendor/bundle`）に置かない。rbenv で選ばれる Ruby（`.ruby-version`）の gem として入るので、`.ruby-version` を変えたら `bundle install` し直す

## 未実施（AWS 環境が必要）

稼働環境での作業と確認手順は [確認手順書: AMI 公開パイプラインの稼働環境での確認](../ami-publish-environment-verification.md)、失敗したときの対処は [トラブルシューティング](../ami-publish-troubleshooting.md) にまとめてある。

- ソースにするリポジトリの用意（このディレクトリの中身をルートとするリポジトリ。決定事項 D2）
- AWS 側の事前準備（リリース用インスタンス、セキュリティグループ、CodeConnections の接続）
- `config/ami_publish.yml` のダミーの値を実際の値に置き換え、再生成・レビュー
- 開発アカウントへのデプロイ、初回の AMI 公開、障害試験（開発計画の M5〜M7）
