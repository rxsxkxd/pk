# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このディレクトリの性格

EC2 の運用・自動化に関する**日本語の設計ドキュメント群**と、その実装である **AMI 公開パイプライン（`ami-publish/`）** が同居している。ドキュメントの追記・修正は日本語で行い、用語はできるだけ省略しない（例: 「生成 YAML」ではなく何の生成物かまで書く）。

- 中心となる設計: `ami-build-pipeline.md`（リリース検証 → AMI 化 → 起動テンプレート）→ 実装範囲を絞った `ami-publish-development-plan.md`（決定事項 D1〜D10 の正本）→ 稼働環境での確認は `ami-publish-environment-verification.md`、失敗時の対処は `ami-publish-troubleshooting.md`
- `*-memo.md` は**採用しなかった・保留中の選択肢の備忘録**。採用済みの設計として扱わない
- 図は Mermaid。見やすさのため縦向き（`flowchart TD`）と `%%{init: ...}%%` の文字サイズ指定を使っている箇所がある
- `samples/nginx-passenger-rails/` は独立した学習用サンプルで、`ami-publish` とは無関係
- リリースの流れは段階ごとにフォルダを並べている: 前段 `release-verification/` → 中段 `ami-publish/` → 後段 `instance-provisioning/`。フェーズの番号は開発の優先順位で、**フェーズ 1 = 中段（実装済み）、フェーズ 2 = 後段、フェーズ 3 = 前段（リリース検証の自動化）**。流れの順番とは一致しない。全体像とフォルダ構成は `README.md`

## ami-publish の全体像

常時起動の**リリース用インスタンス**から AMI を作り、その AMI を指す**起動テンプレートの新しいバージョン**を用意する。スコープは起動テンプレートの用意まで（Auto Scaling グループ・本番インスタンスの構築は対象外）。インスタンス上でのリリース検証（チェックアウト、RSpec）は未実装で、現状は担当者が手作業で済ませてからパイプラインを起動する前提。

実装言語の方針（決定事項 D10）: **クライアント PC で実行するクライアント・CLI ツールは Go、パイプラインの処理は Ruby、シェルスクリプトは最小限。**

現在の分担:

| 部分 | 言語 | いつ・誰が動かすか |
|---|---|---|
| 仕組みの生成ツール `cmd/generate-definitions` + `internal/definitions/` | Go | パイプラインの作成時に担当者が実行。`config/ami_publish.yml` から CloudFormation テンプレート 4 種（仕組みの 3 つと、リリース用インスタンスの IAM ロール）と buildspec を `generated/` に生成。**AWS は呼ばない** |
| AMI 公開ツール `bin/ami_publish` + `lib/ami_publish/` | Ruby 3.4（AWS SDK for Ruby） | パイプラインの実行時に CodeBuild 上で動く（`run`）。`plan`（dry-run）と `rollback` は担当者が手元から実行 |
| シェル | buildspec の数行のみ | Ruby の選択（`rbenv local`）、`bundle install`、ツールの起動、出力値の受け渡し |

仕組み（3 つのスタック: ヘルスチェックの SSM ドキュメント → 起動テンプレート → AMI 公開パイプライン）のデプロイは、担当者が AWS CLI で行う（D9。CI による自動デプロイはしない）。リリース用インスタンスの IAM ロールのスタック（`<app>-<env>-release-instance`）は `generated/deploy/<env>.sh` の `up` / `down` に含めず、個別にデプロイする（フェーズ 3 側に移す可能性があるため。既存インスタンスへの関連付けは AWS CLI）。パイプラインの起動は `aws codepipeline start-pipeline-execution --variables name=VERSION,value=vX.Y.Z`（D3）。

AMI 公開ツールの流れは `lib/ami_publish/commands/publish_command.rb` のステップの並びがそのまま正本:
CheckInstanceState（状態と、インスタンスプロファイルの紐付けが「なし」か自分のものかの確認）→ CheckReleaseInstancePermissions（リリース用インスタンスのロールの許可を IAM のポリシーシミュレーターで判定）→ AttachReleaseInstanceProfile（紐付け）→ CreateImage → WaitImageAvailable → StartInstanceIfStopped（開始時に停止中だった場合だけ起動。停止には戻さない）→ WaitInstanceOnline → HealthCheck → DetachReleaseInstanceProfile（解除）→ UpdateLaunchTemplateStack → PublishOutputs。
ステップは interactor（gem）の Interactor で、並びは Commands の Organizer（`organize`）が決める。値と部品（configuration・clients・logger）は `context`（`Interactor::Context`）で受け渡す。後のステップが失敗すると、interactor が実行済みのステップの `rollback` を逆順に呼ぶ（紐付けの失敗時の解除はこれで行う）。ステップごとのログ（`step_started` など）は `BaseStep` の around フックが出す（around フックは子クラスに引き継がれないので `BaseStep.inherited` で付けている）。
リリース用インスタンスには、ヘルスチェックの区間だけインスタンスプロファイルを紐付ける（`docs/ec2/ami-publish-health-check-role-association-flow.md`）。そのため CodeBuild のロールは、リリース用インスタンスのロールだけを EC2 に渡す `iam:PassRole` を持つ（これ以外の `iam:PassRole` は持たせない。Go のテストで確認）。
`rollback` は FindPublishedImage → UpdateLaunchTemplateStack → PublishOutputs。
ヘルスチェックは既定で行い、パイプライン変数 `HEALTH_CHECK=false`（`--health-check false`）で省略できる。省略時は SSM に依存する処理（紐付けの確認、ロールの許可の確認、紐付けと解除、停止中のインスタンスの起動、接続待ち、ヘルスチェック）をすべて行わず、AMI に `HealthCheck=skipped` を付ける（判定は `BaseStep#health_check?` と `BaseStep#skipped_without_health_check?`）。

## 変更するときに守る前提

- **名前は命名規則、スタック間の参照は Export**: スタック名・パイプライン名・ロググループ・SSM ドキュメント名は設定値に書かず、`application_name` と環境名から決める（Go の `internal/definitions/naming.go`）。パイプラインのスタックは、他のスタックのリソースを命名規則の文字列ではなく Export（`<スタック名>:<項目>`）で参照する。Ruby が命名規則で決めるのはパイプラインのスタック名だけで（`lib/ami_publish/configuration.rb`。Go と同じ規則なので両方直す）、ほかの名前はパイプラインのスタックの出力から引く（`StackOutputs`）。Export しているのは変わらない値だけ（起動テンプレートのバージョンは Export しない）。初回の `up` は 2 回必要
- **`config/ami_publish.yml` は Go が `KnownFields` で厳密に読む**: 未知の項目は生成時にエラー。項目を足すときは Go の構造体と検証も直す（Ruby は必要な項目だけ読む）。頻繁に変えない値（CodeBuild のイメージ `codeBuildImage`、CodeBuild で使う Ruby `codeBuildRubyVersion`）は設定値ではなく `internal/definitions/ami_publish_buildspec.go` の定数
- **`generated/` は手で編集しない**（CloudFormation テンプレート・buildspec に加え、`generated/deploy/<環境>.sh` も生成物。AWS CLI の呼び出しを並べるだけで、チェックなどの処理は入れない）: 定義か設定値を直して再生成し、`--check` で一致を確認する。YAML は順序付きマップ `definitions.M(...)` で書き、組み込み関数は完全形（`Ref:` / `Fn::Sub:`）で出力する（差分でレビューするため、出力順を固定している）
- **起動テンプレートのスタックの更新に CloudFormation のサービスロールは使わない**（CodeBuild のロールに対象の起動テンプレートの操作権限を直接与える。サービスロールを渡すとスタックがロールを覚え、削除や担当者の再デプロイまでそのロールで行われるため）。パイプライン全体に IAM ロールの作成・変更の権限を持たせない（Go のテストで確認）
- **起動テンプレートのスタックは、パイプラインがパラメータ `AmiId` / `AppVersion` だけを変える**: 変更セットに `AWS::EC2::LaunchTemplate` の Modify 以外が含まれたら中止する。スタックに Auto Scaling グループなど本番リソースを入れない。起動テンプレートに UserData・サブネットは入れない。`AmiId` は初回は空でよい
- **失敗時の AMI**: ステップ 2〜4（と起動失敗）で失敗したら AMI とスナップショットを削除（D5）。ステップ 5 の失敗では残し、同じ実行の再試行で再利用する。古い AMI の整理はこのパイプラインでは行わない（D8）
- **権限の方針**: CodeBuild のロールに `AWS-RunShellScript` や `ec2:StopInstances` を与えない（Go のテストで確認している）。AWS に書き込む箇所には `# [変更]` コメントを付けている
- **待機処理には進捗ログを出す**: 待つ処理を足すときは `progress_logger` / `configure_waiter(..., progress:)` を使い、`timeouts.progress_log_interval_seconds` ごとに `"event":"waiting"` を出す
- **Ruby のバージョン**: 手元は `.ruby-version`（3.4 系の最新）。CodeBuild はイメージにある 3.4 系を `rbenv local` で選ぶ（パッチバージョンのずれは許容）。`Gemfile.lock` の `PLATFORMS` から `x86_64-linux` / `aarch64-linux` を消さない（CodeBuild の deployment モードで失敗する）

## コマンド

`ami-publish/` で実行する。

```bash
# Go: 仕組みの生成と確認（オフラインで動く）
go run ./cmd/generate-definitions            # generated/ に生成し、自動で決まる名前の一覧を表示
bash generated/deploy/staging.sh up          # 仕組みのデプロイ（変更セットを作るだけ。確認後に担当者が反映する）
bash generated/deploy/staging.sh down        # 仕組みの撤去（逆順にスタックを削除。確認の問い合わせはない）
go run ./cmd/generate-definitions --check    # 定義・設定値と generated/ の一致確認（終了コード 1 = 差分あり）
go test ./...
go test ./internal/definitions -run TestPipelineStack   # 単一テスト
cfn-lint generated/cloudformation/*/*.yml    # 別途インストールが必要

# Ruby: AMI 公開ツール（テストは AWS SDK の stub_responses で、AWS に接続しない）
bundle exec rspec
bundle exec rspec spec/ami_publish/steps/health_check_spec.rb      # 単一ファイル（:<行番号> で単一テスト）
bundle exec rubocop

# AWS を使う実行（認証情報が必要。plan も読み取り API を呼ぶ）
AWS_PROFILE=<profile> bundle exec ruby bin/ami_publish plan --environment staging --version v1.2.3
AWS_PROFILE=<profile> bundle exec ruby bin/ami_publish rollback --environment staging --to-version v1.2.2 --dry-run
```

- Ruby のツールは `ruby bin/ami_publish` の形で呼ぶ（CodePipeline のアーティファクトで実行ビットが落ちるため）
- 終了コード: Go の生成ツールは 0 / 1（`--check` の差分）/ 2（使い方・設定値）/ 3（ファイル操作）。AMI 公開ツールは 0 / 1（ステップの失敗）/ 2（使い方・設定値）/ 3（AWS のエラー・認証情報なし・接続不可）
- 手元では gem をリポジトリ内（`vendor/bundle`）に置かない（`bundle config set path` を設定しない）。rbenv の Ruby（`.ruby-version`）の gem として入る。`.ruby-version` を変えたら `bundle install` し直す。CodeBuild は buildspec の deployment モードで、ビルド環境の中の `vendor/bundle` に入れる
- パイプラインのソースは「`ami-publish/` の中身をルートとする別リポジトリ」を前提にしている（buildspec のパスがリポジトリのルート基準）。この `pk` リポジトリのままではパイプラインから動かない
