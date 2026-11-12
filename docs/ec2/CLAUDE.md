# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このディレクトリの性格

EC2 の運用・自動化に関する**日本語の設計ドキュメント群**と、その実装である **AMI 公開パイプライン（`ami-publish/`）** が同居している。ドキュメントの追記・修正は日本語で行い、用語はできるだけ省略しない（例: 「生成 YAML」ではなく何の生成物かまで書く）。

取り違えやすい表現は、正確な名前を決めて明示する。「対象のサーバー」「対象」のように文脈で指すものが変わる語をそのまま使わず、役割が分かる名前（例: 「稼働サーバー」「中継サーバー」）を決める。1 つのドキュメントの中では、同じものは同じ名前で、違うものは違う名前で書く。役割の近いものが複数出てくるドキュメントでは、冒頭の「用語」の節で定義する。

- 中心となる設計: `ami-build-pipeline.md`（リリース検証 → AMI 化 → 起動テンプレート）→ 実装範囲を絞った `ami-publish-development-plan.md`（決定事項 D1〜D10 の正本）→ 稼働環境での確認は `ami-publish-environment-verification.md`、失敗時の対処は `ami-publish-troubleshooting.md`。主要なドキュメント以外の調査・補足のドキュメントとメモは `notes/` に置く（段階ごとに `notes/ami-publish/`・`notes/release-verification/`・`notes/instance-provisioning/`、EC2 の運用に関する個別の調査は `notes/ec2-operations/`）
- `*-memo.md` は**採用しなかった・保留中の選択肢の備忘録**。採用済みの設計として扱わない
- 図は Mermaid。見やすさのため縦向き（`flowchart TD`）と `%%{init: ...}%%` の文字サイズ指定を使っている箇所がある
- `samples/nginx-passenger-rails/` は独立した学習用サンプルで、`ami-publish` とは無関係
- **今の前提（2026-10-28 から）: 今の構成（AL2・Apache・Passenger・Rails 4.2・Ruby 2.7.7）の AL2023 での作り直しは緊急の対応。Rails 6 以上のことは一切考えない**（検討・提案・ドキュメントに含めない）。アプリの側を上げる話は Rails 5.x までに限る。Ruby 3 には Rails 6.1 以上が要るので、Ruby も 2.7 系が前提になる。検討の内容は `initial-image-build/existing-system-rebuild-on-al2023.md`
- 今の環境（AL2）への暫定対応の道具は、**2 つのフェーズに完全に分けている**（リリースの流れのフェーズ 1〜3 とは別の番号。別のフォルダ・別の道具・別のバックアップ。AMI のタグ `Purpose` で分ける）。どちらも標準のライブラリだけ、AWS の操作は AWS CLI のコマンドを呼ぶ。決定事項 D10（作業者の PC の道具は Go）は ami-publish の方針で、これらの道具には当てはめない。リリースの流れの段階とは別。どちらも、バックアップ（AMI の作成と確認）は本体と別のコマンドに分けている（2 つの道具のバックアップは統合しない）。確定した内容以外の事項（cron など）は道具に入れない
  - 暫定対応のフェーズ 1 `ssm-setup/`: 運用中の稼働サーバーを SSM で入れる状態にする。**操作を 3 つに分け、別々の区分の操作を 1 つのコマンドに入れない**: AWS の操作は Ruby（`rb/`。Ruby 2.6 以上、標準のライブラリだけで gem は使わない）、接続の確認は sh（`connect/ssm-connect-check.sh`。作業者の PC と踏み台サーバーの両方で流す。既定で Session Manager と Run Command の両方を確かめる）、インスタンスの中の操作は sh（`instance/agent-check.sh`・`agent-install.sh`。AWS は呼ばない）。流れは `rb/ssm_role.rb`（IAM ロールが未設定の台にインスタンスプロファイルを関連付けるだけ。既存のロールに権限を足すことはしない）→ `rb/ssm_check.rb`（権限と AWS の上の状態だけ。SSM 有効・SSM Agent で直す・手で直すに分け、`--ok-out` / `--ng-out` で一覧を書き出す）→ `connect/ssm-connect-check.sh`（事前の確認をせず、`echo` で実接続だけを見る）→ SSM Agent で直す台だけ `rb/backup.rb` → `rb/backup_check.rb --ok-out`（そろった台の一覧）→ その台にだけ `instance/` のスクリプト → もう一度 `rb/ssm_check.rb` → `connect/ssm-connect-check.sh`。**踏み台サーバーから稼働サーバーへの SSH での操作（`instance/` のスクリプトを届けて流すこと、接続先の決め方）は範囲外**（別の枠組みで行う。SSM に一本化するかは ssm-setup の外で検討）。踏み台サーバーには、接続の確認のための IAM ロール（`cloudformation/bastion-role.yml`）を付ける。設定を変える `ssm_role.rb`・`backup.rb` は、確かめる（Plan を作る）と行う（ブロック）だけを書き、表示・確認・1 台ごとの失敗・終了コードは `rb/flow.rb` に任せる。手順の正本は `ssm-setup/steps.md`。書き方は rubocop の既定で、gem を置かないので `cd ssm-setup/rb && BUNDLE_GEMFILE=../../al2-update/rb/Gemfile bundle exec rubocop`。テストはない
  - 暫定対応のフェーズ 2 `port-guard-rollout/`: **80・443 番だけ**を国内と許可した IP に絞る設定（iptables ＋ ipset）を複数台まとめて入れる（`python3 -m port_guard_rollout`。`install` → `enable`。その前のバックアップは `python3 -m port_guard_rollout_backup`。フェーズ 1 の `ssm-connect-check` で入れる台を、SSM の Run Command（`--via ssm`。SSH も可）で操作する）。SSH の 22 番は既定では絞らない（外部からの SSH はセキュリティグループで弾く前提。`install --include-ssh` で対象にできる準備はある）。手順の正本は `port-guard-rollout/steps.md`、仕組みは `port-guard-rollout/iptables-ipset.md`。Python 版は `py/`、機能を絞った sh 版は `sh/`、Ruby 版は `rb/`（sh 版と Ruby 版は SSM の Run Command だけ。Ruby 版の書き方は rubocop の既定で、`cd port-guard-rollout/rb && bundle exec rubocop`）。インスタンスに送るものは 3 つで共用する `remote/`。Python 版のバックアップは別のパッケージ `port_guard_rollout_backup/`（本体の部品を使い、本体は操作の前の確認だけを使う）。インスタンスを操作するコマンドは、確かめる（`plan`）と行う（`apply`）だけを書き、入力・前提の確認（`Stop`）・表示・確認・1 台ごとの失敗（`Failed`）・終了コードは共通の流れ `flow.py` に任せる（`enable` は 1 台ごとに確かめるので部品だけを使う。バックアップの `check` は使わない）。共通の部品（`awscli.py`・`ssh.py`・`runcommand.py`・`flow.py`・`backup.py` など）は、もとは ssm-setup の Python 版と写し合っていたが、ssm-setup は Ruby と sh に作り直したので、今は port-guard-rollout だけが持つ。テストは `cd port-guard-rollout/py && python3 -m unittest discover -s tests`（AWS・SSH には接続しない）
- `sg-ssh-restrict/`: セキュリティグループの 22 番（SSH）を許可する範囲に絞る Ruby の道具（2 つのフェーズとは別の作業。標準のライブラリだけ、AWS CLI を呼ぶ）。A `rb/restrict_rule.rb`（今のグループの規則を直す。そのグループを付けた全台に効く）と B `rb/swap_groups.rb`（22 番を除いた写しと 22 番を絞ったグループに付け替える。付け替えた台だけ）の両方を用意していて、どちらを使うかは環境を見て決める。どちらも `--check-only`、変えた内容の記録、`rb/restore.rb` で元に戻す。書き方は rubocop の既定（`cd sg-ssh-restrict/rb && bundle exec rubocop`）。説明は `sg-ssh-restrict/README.md`
- `al2-update/`: 運用中の AL2 のインスタンスで OS のパッケージを yum で複数台まとめて更新する Ruby の道具（2 つのフェーズとは別の作業。標準のライブラリだけ、AWS CLI を呼び、SSM の Run Command で 1 台ずつ。インスタンスに送るものは `remote/`）。`rb/check.rb`（更新の確認。読み取りだけ）→ `rb/backup.rb`・`rb/backup_check.rb`（AMI。タグ `Purpose=al2-update-backup`）→ `rb/update.rb`（既定はセキュリティの更新だけ、Apache の `httpd*`・`mod_*` は既定で除き、`amazon-ssm-agent` はいつも除く。httpd とアプリの応答が悪くなったら残りを止める。再起動はしない）。書き方は rubocop の既定（`cd al2-update/rb && bundle exec rubocop`）。説明は `al2-update/README.md`
- リリースの流れは段階ごとにフォルダを並べている: 起点 `initial-image-build/`（ソースからの最初のイメージの作成。未着手）→ 前段 `release-verification/` → 中段 `ami-publish/` → 後段 `instance-provisioning/`。フェーズの番号は開発の優先順位で、**フェーズ 1 = 中段（実装済み）、フェーズ 2 = 後段、フェーズ 3 = 前段（リリース検証の自動化）**。流れの順番とは一致しない。全体像とフォルダ構成は `README.md`

## AWS について調べるとき

AWS の仕様・挙動・制限をドキュメントに書くときは、**一次情報を AWS 自身の公開の情報で確かめる**。記憶や第三者の記事だけを根拠にしない。

| 種類 | 情報源 | 扱い |
|---|---|---|
| 仕様・挙動・設定の仕方・制限 | `docs.aws.amazon.com`（各サービスのユーザーガイド、API リファレンス、AWS CLI のリファレンス） | **一次情報の基本**。まずここを辿る |
| 料金 | `aws.amazon.com/<サービス>/pricing/` | 一次情報。数値は変わるので、書くなら調べた日を添える |
| 新機能・変更の発表 | `aws.amazon.com/about-aws/whats-new/` | 一次情報（いつから使えるかの確認に） |
| AWS のブログ（`aws.amazon.com/blogs/`）、AWS re:Post（`repost.aws`） | AWS の公開の情報だが、書かれた時点の情報で、古くなっていることがある | 補助。仕様の根拠にするときは `docs.aws.amazon.com` でも確かめる |
| AWS 以外のブログ・記事・回答 | — | 一次情報としない（手がかりとして使い、`docs.aws.amazon.com` で確かめ直す） |

- ドキュメントには、根拠にした AWS のページへのリンクと、確かめた日を書き残す（例: 「AWS のドキュメントと照らし合わせた（2026-11-05）」と「参考」の節）
- 確かめられなかったこと（AWS のドキュメントに書かれていない、実機で試していない）は、そう明記する。推測で断定しない

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
リリース用インスタンスには、ヘルスチェックの区間だけインスタンスプロファイルを紐付ける（`docs/ec2/notes/ami-publish/ami-publish-health-check-role-association-flow.md`）。そのため CodeBuild のロールは、リリース用インスタンスのロールだけを EC2 に渡す `iam:PassRole` を持つ（これ以外の `iam:PassRole` は持たせない。Go のテストで確認）。
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
