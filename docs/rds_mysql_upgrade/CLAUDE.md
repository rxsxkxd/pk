# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの性格

AWS RDS for MySQL 8.0 → 8.4 を Blue/Green Deployments で移行するための、**手順書（Markdown）と実行スクリプトと CI 定義が一体になったリポジトリ**である。アプリケーションコードではなく、テストスイートやビルド成果物も持たない。ドキュメントは日本語で書かれており、追記・修正も日本語で行う。

期限は MySQL 8.0 の標準サポート終了（2026-07-31、8/1 以降は Extended Support が自動課金）であり、`docs/rds-mysql-84-migration-guide.md` が全体の親ドキュメントである。

## 全体アーキテクチャ

### Step 1〜7 の分割

**実運用の手順は 2 本に集約してある。**`operations-environment-setup.md`（環境構築。CloudFormation でパイプラインを作るまで。一度だけ）と `operations-migration-run.md`（移行の実行。事前チェック・設定生成からパイプラインでの移行まで。対象ごとに繰り返す）である。**オペレーション手順を書き足すときは、まずこの 2 本のどちらかに属するかを考える。**個々のチェックの中身や背景は補足ドキュメント側に置き、2 本からはリンクする。

`docs/upgrade-flow-steps.md` が中心的な設計ドキュメントで、移行手順書の Phase 0〜5 を再実行可能な 7 ステップへ割り直している。**新しいスクリプトや CI ジョブを追加するときは、まずこのファイルの分類（実行形態・ワンストップ実行・承認要否）に照らす。**

| Step | 内容 | 実行形態 | エントリポイント |
|---|---|---|---|
| 1 | 既存 Blue の成立条件チェック | ローカル | `collect_blue_green_prereqs.sh` → `evaluate_blue_green_prereqs.rb` |
| 2 | 8.4 パラメータグループの整理・生成・CFn 適用 | ローカル | `collect_mysql84_parameter_inputs.sh` → `generate_mysql84_parameter_group.rb` |
| 3 | 保護スナップショット＋Blue/Green 作成 | CI | `build_green.sh` → `create_blue_green_deployment.sh` |
| 4 | Green 構成・レプリカ同期の検証 | CI | `verify_green.sh` |
| 5 | 切替 | CI（承認付き） | `switchover.sh` → `switchover_blue_green_deployment.sh` |
| 6 | Green ヘルスチェック | CI（AWS API）＋ローカル（DB 接続） | 未実装 |
| 7 | 後始末（旧 Blue 削除） | CI（承認付き） | 未実装 |

### 設計上の中核ルール

これらは既存コードの随所に埋め込まれている。逸脱する変更を入れない。

- **収集と判定を分離する。** シェルスクリプトは AWS CLI の読み取り API（`Describe*`／`Get*`）で JSON を `--output-dir` に落とすだけ、判定は AWS を呼ばない Ruby／Go／インライン Python が行う。変更操作を行う行には `# [変更]` のコメントが付いている。
- **判定系は不適合時に終了コード `1` を返す。** CI のジョブ失敗としてそのまま扱う（例: `generate_mysql84_parameter_group.rb` は「要レビュー」が残ると `1`）。
- **宣言と実環境の突き合わせ（reconciliation）。** 設定ファイルは進捗の記録ではなく「このアクションを実行してよい」という人間の宣言（`pending` / `approved`）を持つ。CI は毎回 AWS の実状態を読み、未適用なら適用、適用済みなら何もしない。**CI が設定ファイルへ書き戻すことはしない。** `approved` → `pending` に戻しても適用済みのものは取り消さない。
- **識別子は AWS から引き当てる。** Deployment ID を設定ファイルに持たず、`describe-blue-green-deployments --filters Name=source,Values=$source_arn` で毎回解決する。これにより再実行・リトライ・同時トリガーで二重作成・二重切替が起こらない。
- **冪等性は二層で担保する。** ① 移行元インスタンスのエンジンバージョンとパラメータグループで「結果」を観測し（`scripts/lib/migration_phase.sh`）、② Deployment の `Status` を安全弁として併用する。切替時に blue が `-old1` へリネームされるため、`source_db_instance_identifier` が指す実体は切替の前後で変わる。この判定は Deployment が cleanup で削除された後も機能する。**終了コードは「操作を実行したか」ではなく「望ましい終了状態に到達しているか」で決める**（到達 = `0`、未到達かつ自動では到達不能 = `1`）。設計の背景は `decisions/idempotency-strategy.md`。
- **本番 DB の認証情報を CI に常設しない。** DB 接続を伴う確認はローカルのコンテナから対話パスワードで行う。MySQL 接続は設定ファイルの `mysql_verification` が制御する（既定 `enabled: false`）。パスワードの取得方法は `auth_method` で選ぶ（`parameter_store` / `plaintext` / `prompt`）。**読むパラメータ名は config（サービスごと）が決め、CloudFormation の `MySqlCredentialsParameterArns` は `ssm:GetParameter` を許す ARN の列挙にすぎない**——パイプラインは環境ごとに 1 本なので、その環境で扱う全サービス分の ARN を渡す。SecureString がカスタマー管理キーなら `MySqlCredentialsKmsKeyArn` も渡す（`kms:ViaService` で SSM 経由に限定した `kms:Decrypt` が付く。AWS 管理キーなら不要で、復号は SSM 側なので `kms` の VPC endpoint は要らない）。**`parameter_store` ではユーザー名も必ず秘匿側へ置く**——`parameter_name`（パスワード）と `user_parameter_name`（ユーザー名）の両方が必須で、config の `user` は使わない。`plaintext` / `prompt` では config の `user` が必須である。解決は `scripts/lib/mysql_credentials.sh` が担い、値は `MYSQL_PWD` として MySQL クライアントのプロセスにだけ渡す。**`plaintext` は設定ファイルが Git 追跡対象であるためテスト環境専用で、`environment: production` では拒否される。** **カタログからの生成（`generate_blue_green_config`）は `auth_method: parameter_store` 固定で出力する。**`secrets_manager` と `iam`（IAM データベース認証）は対応しない——不正な `auth_method` として拒否される。
- **RDS パラメータグループの変更経路は CloudFormation のみ。** Blue/Green Deployment 自体は CFn カスタムリソースを使わず AWS CLI で扱う。
- 破壊的 RDS 権限（`rds:DeleteDBInstance` 等）は CI 実行ロールにのみ付与する。作業者には CloudFormation スタック操作権限だけを与える。
- **移行元が拡張モニタリング（Enhanced Monitoring）を使っている場合、Step 3 の実行ロールに `iam:PassRole` が要る。**Blue/Green 作成時に RDS が Green へその設定をコピーするためで、無いと `create-blue-green-deployment` が `AccessDenied` で失敗する。`codepipeline-all-in-one.yml` の `RdsMonitoringRoleName`（既定 `rds-monitoring-role`、空なら付与しない）で対象を指定し、`iam:PassedToService: monitoring.rds.amazonaws.com` の Condition で渡し先を固定する。

### 設定ファイル

`config/blue-green/{staging,production}.deployment.yml` が環境ごとの単一の入力である。全スクリプトが `--config FILE --service NAME` だけを引数に取り、DB 識別子・バージョン・パラメータグループ名・`actions` の承認状態をここから解決する。

Blue/Green 設定 YAML は `config/migration-catalog.yml`（人が管理する接続定義）と RDS インベントリから生成できる。**収集と生成は別コマンドで、ロジックは `tools/internal/` のライブラリにある。**

| パッケージ | 役割 |
|---|---|
| `tools/internal/common` | 収集器が書き生成器が読む**インベントリ JSON の型（契約）**、原子的ファイル書き込み |
| `tools/internal/collect` | AWS CLI を exec し `describe-db-instances` とパラメータグループごとの `describe-db-parameters` だけを呼ぶ |
| `tools/internal/generate` | カタログの検証・解決と、deployment YAML の組み立て。**AWS を呼ばない** |
| `tools/internal/report` | 切替前レビュー用の Markdown 組み立て。判定は行わず、`tools/internal/generate` を再利用して材料を並べる |
| `tools/internal/cfn` | Step 2 の CloudFormation テンプレートから DB パラメータグループの宣言値を読む。**短縮記法を長形式へ正規化**し、組み込み関数の項目は「比較不能」として扱う |

**フォルダの分け方**——`scripts/` は **CI（buildspec）から到達するものだけ**である。人が手で実行するものは置かない。

| ディレクトリ | 中身 |
|---|---|
| `scripts/` | CI から到達する実行スクリプトと、その共有ライブラリ（`lib/` / `internal/`）、Step 4 のレポート生成器 |
| `tools/` | **人が手で実行するもの一式。**Step 1・2 の収集・判定（`collect_blue_green_prereqs.sh` / `evaluate_blue_green_prereqs.rb` / `collect_mysql84_parameter_inputs.sh` / `generate_mysql84_parameter_group.rb`）、Blue/Green 設定の Go コマンド（`collect_rds_instance_inventory` / `generate_blue_green_config` / `generate_blue_green_config_report`）と、そのライブラリ（`internal/`）。個別実行手順は `tools/README.md` |
| `tests/` | テスト一式 |

**`scripts/internal/` と `tools/internal/` は共有しない。**CI から到達する側と人が実行する側を独立させるための方針で、Go の `internal/` 可視性がそれを強制する。唯一内容が重なる `cfn` は両方に複製して置いており、**片方を直したらもう片方へ同じ変更を入れる**（`tests/cfn_shorthand_test.sh` が 2 本の一致を検査するので、ずれるとテストが落ちる）。

`docs/upgrade-flow-steps.md` の Step 1・2 の実装リンクも `tools/` を指すよう更新済みである（`docs/` への移動で相対パスを書き換える必要があったため、併せて解消した）。**同ファイルはレビュー中につき、内容と Step の番号体系は変更しない。**

コマンドは 3 つに分かれており、`collect_rds_instance_inventory/`・`generate_blue_green_config/`・`generate_blue_green_config_report/` はいずれも CLI の配線だけを持つ薄い `main` である。**レポートは設定ファイルを書き換えず、`.md` だけを出す**（生成物の `connected_by` を持たない代わりに、アプリと接続の対応はレポートで示す）。**判定ロジックを変えるときは `tools/internal/` 側とその単体テストを直す。**生成結果の `source_db_parameters` は Blue のパラメータグループから採取した実値（パラメータ名をキーにした `value` / `source`。採取対象は `tools/internal/collect` の `CollectedParameters` で決め、現在は `time_zone` のみ）で、**切替前の人のレビュー専用**——実行スクリプトは読まない。レポートはこれと移行先テンプレートの宣言値を突き合わせて `一致` / `差異` / `比較不能` を示す。設計は `docs/config-blue-green-generation-design.md`、カタログの構造は `docs/migration-catalog-er.md` を正とする。**レポート生成器は全部で 3 つあり**（①設定レビュー / ②Step 2 のパラメータ変換 `generate_mysql84_parameter_group.rb` / ③Step 4 の Green 検証）、いずれも **AWS を呼ばず収集済みファイルだけを読む**。全体像は `report-generation-flows.md` にある。

`config/mysql80-to-84-parameter-rules.yml` は 8.0 → 8.4 のパラメータ変換ルール（`copy` / `force` / `omit` / `target_only`）を持ち、`generate_mysql84_parameter_group.rb` の唯一のルールソースである。パラメータの扱いを変えるときはスクリプトではなくこの YAML を編集する。

### CI の二系統

同じ `scripts/*.sh` を GitHub Actions と CodeBuild/CodePipeline の両方から実行する。**スクリプトを変更したら両方の呼び出し側を確認する。**

- `.github/workflows/{build-green,verify-green,switchover}.yml` — `workflow_dispatch` のみ。OIDC で `vars.AWS_ROLE_ARN` を引き受ける。`env.ACT` が真のとき（nektos/act）は OIDC ステップを飛ばし、ローカル配置の AWS CLI zip を入れる分岐が入っている。
- `ci/codebuild/*.yml` + `examples/rds-blue-green-deployment/codepipeline.yml` — `BuildGreen → VerifyGreen → ManualApproval → Switchover`。**アーティファクト用 S3 バケットは `codepipeline-all-in-one.yml` だけが作れる**（`ArtifactBucketName` を空にすると新規作成。バージョニング必須なので有効化し、`DeletionPolicy: Retain` でスタック削除時も残す——中身があると S3 は削除できずスタック削除が失敗するため）。`DetectChanges: false` で push では起動しない。**ソースの取得元は `SourceProvider` パラメータで `CodeConnections`（GitHub。既定）と `CodeCommit` を切り替える。**Source ステージのアクションと CodePipeline ロールの権限だけが入れ替わり、後続ステージはどちらも `SourceOutput` を受け取るので、切り替えの影響は Source ステージに閉じている。

**Step 4 の実効値収集は MySQL クライアントを使わない。**`scripts/collect_green_runtime_values/`（Go）が `performance_schema.global_variables` を直接読む。理由は次の 2 つで、どちらも「実行時に mysql クライアントを導入できない」ことに帰着する。

- VerifyGreen は RDS のある VPC 内で動かす場合があり、そこから apt リポジトリへ到達できない
- `aws/codebuild/standard:7.0` は mysql クライアントを含まない（`libmysqlclient-dev` は開発用ライブラリである）

収集対象のパラメータ名は、このバイナリが CloudFormation テンプレートから直接読む（`scripts/internal/cfn` の `ParameterNames`）。値が組み込み関数の項目は実値が決まらないため、比較対象から外して「比較不能」と表示し、ドリフト判定にも含めない。fixture とテストは `examples/cfn-shorthand/` にある。

**TLS は VERIFY_CA 相当である。**証明書チェーンは検証し、**ホスト名は検証しない**（MySQL クライアントの `--ssl-mode=VERIFY_CA` と同じ挙動）。RDS のトラストストア（`scripts/collect_green_runtime_values/rds-global-bundle.pem`、AWS が公開する 165KB の公開情報）を `go:embed` でバイナリへ焼き込んであるため、**実行時に CA ファイルを用意する必要がない**。config の `ssl_ca` を指定した場合だけそのバンドルへ差し替える。バンドルの更新はこれだけである。

```bash
curl -o scripts/collect_green_runtime_values/rds-global-bundle.pem \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

`scripts/collect_green_runtime_values.sh` はバイナリの場所を決めてパスワードを環境変数で渡すだけの薄いラッパーである。パスワードはコマンド引数・成果物に出さない。`auth_method: prompt` のときはここで対話入力を促す（エコーしない）。

**Step 4 は同じ Go プログラムで 2 つの実行形態を賄う。**MySQL 実効値の収集は Green DB への到達が必要で、リモート（CodeBuild）では VPC 構成が別途要るため成立しない場合がある。そのときは MySQL 接続を伴う確認をローカルから行い、レポート出力までローカルで完結させる。

| 実行形態 | MySQL 接続 | レポート生成器へ渡す引数 | 「MySQL 実効値」列 |
|---|---|---|---|
| リモート（CodeBuild／GitHub Actions） | しない | `--runtime-values` を渡さない | `未収集` |
| ローカル | する | `--runtime-values <収集結果 JSON>` | 収集した実効値 |

**実効値の有無で変わるのはこの列だけで、判定は AWS API から取得した値で行う。**リモートでも判定内容は変わらない。この性質は `tests/cfn_shorthand_test.sh` が両形態を突き合わせて固定しているので、**レポート生成器を変更したら両形態のテストを通すこと。**

**Step 4 が使う Go バイナリは 2 本で、どちらも `BuildReportTool` が作って artifact で渡す。**

| バイナリ | ソース | 役割 | 受け取る環境変数 |
|---|---|---|---|
| `generate_green_verification_report` | `scripts/`（package main） | レポート（`.md`）の組み立て | `GREEN_REPORT_GENERATOR` |
| `collect_green_runtime_values` | `scripts/collect_green_runtime_values/` | Green DB の実効値収集 | `GREEN_RUNTIME_COLLECTOR` |

**VerifyGreen はどちらもビルドしない。**片方でも欠けていれば理由を出して停止する（Go も外部ネットワークも持たない前提のため、自動復旧しない）。ローカル実行で環境変数を指定しなかった場合だけ、各スクリプトが一時ファイルへビルドして使う。Docker は使わない（`PrivilegedMode` も不要）。

**CodeBuild のイメージは全プロジェクトで `aws/codebuild/standard:7.0` 固定である。**カスタムイメージを指定する経路はテンプレートから削除してある（`VerifyGreenImage` パラメータ・`ImagePullCredentialsType`・ECR 読み取り権限を撤去）。同イメージは jq・rbenv（Ruby 3.4.10）・AWS CLI v2 を持ち、欠けていた mysql クライアントは Go バイナリで置き換えたためである。旧方式の `ci/Dockerfile.verify-green` は**未使用のまま参考として残している**（冒頭にその旨を明記）。

**CloudFormation テンプレートの読み取りは `internal/cfn` が担う。**短縮記法（`!Ref` / `!Sub`）を長形式へ正規化し、値が組み込み関数の項目は「比較不能」として比較対象から外す。レポート生成器の `--list-parameter-names` が `scripts/internal/cfn` を、`tools/generate_blue_green_config_report` が `tools/internal/cfn` を使う。**この 2 本は同一内容の複製なので、短縮記法の扱いを変えるときは両方を直す**（`tests/cfn_shorthand_test.sh` が一致を検査する）。

## 実行方法

### 前提

### 実装言語の使い分け

**プログラムは Go、シェルからの設定 YAML 読み取りだけ Ruby、JSON の取り出しは jq。**理由と適用範囲は `decisions/implementation-language-policy.md`（採択済み）にある。

- **新しいプログラムは Go で書く。**
- 既存の Ruby（`evaluate_blue_green_prereqs.rb`、`generate_mysql84_parameter_group.rb`）は**一律には移行しない。**テスト可能性が問題になったものから順に移す。`.rb` を全廃しても、設定 YAML の読み取りが Ruby ランタイムを要求し続けるため依存は消えない
- `examples/mysql-timezone-replication/probe/` の Go / Ruby / Python は**移行対象外**である。ドライバごとの `time_zone` の扱いの違いを示すことが目的で、3 実装が並ぶこと自体が結論の根拠になっている

シェルスクリプトのデータ読み取りは **jq に一本化**している。YAML を JSON にする **Ruby の 1 行**だけが例外で（jq は YAML を読めないため）、その 1 行は `scripts/lib/deployment_config.sh` にしかない。**YAML / JSON はどちらも Ruby の標準ライブラリ（psych / json）なので、追加パッケージの導入は要らない。**

- 設定 YAML → `deployment_config_vars <config> <service> '<jq フィルタ>'` で読む。フィルタは「どのキーを、どの名前のシェル変数へ、必須か任意か」だけを宣言する。共通関数（`required` / `optional` / `service` / `shellvars`）も同じファイルにある
- AWS 応答などの JSON → jq で直接読む
- **スクリプトに Python を書かない。**設定の読み取りは上の 1 経路だけで、YAML を扱うのは Ruby、それ以外は jq である
- CodeBuild では各 buildspec が install フェーズで `rbenv local 3.4.10` を実行して Ruby を選ぶ（image 同梱の rbenv を使う。パッケージの追加導入は無く、PyPI へも到達しない）

ローカルで Step 3〜5 を直接実行する前に、必要なコマンドがあることを確認する:

```bash
ruby --version && jq --version
```

Blue/Green 設定の収集・生成コマンドは Go である。**`go.mod` と `go.sum` はリポジトリ直下**に置き（`scripts/` 配下ではない）、`go run ./scripts/<コマンド名>` で実行する。こうしておくと go コマンドが作業ディレクトリを変えないため、**引数の相対パスが実行時のカレントディレクトリ基準で解決される**。`go -C scripts run ./<コマンド名>` と書くと cwd が `scripts/` へ移り、相対パスが `scripts/` 配下へ出てしまう。

`go run` は cwd がモジュール内にあることを要求する。リポジトリ外から実行する場合はバイナリを作って渡す:

```bash
go build -o /tmp/collect-rds-inventory ./tools/collect_rds_instance_inventory
```

AWS CLI・MySQL クライアント・Ruby・Go はローカルインストールせず、`compose.yaml` のコンテナで実行できる（`docs/local-execution.md`）。実接続時だけ `.env` を作り、ホストの `~/.aws`・RDS CA bundle・`my.cnf` を絶対パスで指す。**ファイルはすべて `read_only` マウント**である。

STS の一時認証情報（`AWS_ACCESS_KEY_ID`／`AWS_SECRET_ACCESS_KEY`／`AWS_SESSION_TOKEN`）だけは環境変数で転送する。ファイルを書き換えないため `read_only` 方針と両立する。`.env` には書かない。**`AWS_REGION` は転送しない**——空文字がプロファイルの `region` 設定を上書きしてリージョン未指定エラーになるため。リージョンは各スクリプトの `--region` で指定する。

```bash
docker compose --env-file .env run --rm awscli sts get-caller-identity
docker compose --env-file .env run --rm ruby tools/generate_mysql84_parameter_group.rb --help
```

### 各 Step

```bash
# Step 1: 収集 → 判定（STOP が残る間は先へ進まない）
# --output でゲート①の判断材料レポート（観測値と取得元つき）も出せる。
tools/collect_blue_green_prereqs.sh --db-instance-id <blue-id> --region <region> --profile <profile>
ruby tools/evaluate_blue_green_prereqs.rb --input-dir <収集先> --output <収集先>/prereqs-evaluation-report.md

# Step 2: 収集 → ルール突合 → レポートと CFn テンプレート生成
tools/collect_mysql84_parameter_inputs.sh --source-parameter-group <8.0-pg-name>
ruby tools/generate_mysql84_parameter_group.rb --input-dir <dir> --output-dir <dir> --system <name> --environment <env>

# Step 3〜5（CI と同じエントリポイント。設定が pending なら 3/5 は何もせず正常終了）
scripts/build_green.sh   --config config/blue-green/staging.deployment.yml --service example-service
scripts/verify_green.sh  --config config/blue-green/staging.deployment.yml --service example-service
scripts/switchover.sh    --config config/blue-green/staging.deployment.yml --service example-service --approve
```

### 変更の検証

網羅的な自動テストはない。代わりに次で確認する。

```bash
# シェル構文チェック
bash -n scripts/*.sh scripts/lib/*.sh tools/*.sh tests/*.sh

# 移行フェーズ判定のテーブル駆動テスト（AWS へ接続しない）
tests/migration_phase_test.sh

# 設定 YAML の読み取りテスト（AWS へ接続しない）
tests/deployment_config_test.sh

# MySQL 接続方式の解決テスト（AWS へ接続しない）
tests/mysql_credentials_test.sh

# CloudFormation 短縮記法（!Ref / !Sub）を 3 実装が同じに解釈するかのテスト
tests/cfn_shorthand_test.sh

# 変数展開の直後に全角文字が来ていないかの点検（`$VAR）` は変数名の一部と解釈され
# set -u 下で unbound variable になる。`${VAR}）` と書く）
grep -nP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' scripts/*.sh scripts/lib/*.sh tools/*.sh

# Ruby スクリプトの回帰確認（サンプル入力で再生成し、examples/ の出力との差分を見る）
# このサンプルは「要レビュー」が 1 件残るため終了コード 1 が正常
ruby tools/generate_mysql84_parameter_group.rb \
  --input-dir examples/mysql84-parameter-generation/input \
  --output-dir examples/mysql84-parameter-generation/output \
  --system example --environment production

# Go（レポート生成器、RDS インベントリ収集器、Blue/Green 設定生成器）
# ロジックは tools/internal/{common,collect,generate} にあり、単体テストを持つ。
go vet ./... && go build ./... && go test ./...

# GitHub Actions をローカル実行（.actrc に AWS profile と絶対パスマウントを設定してから）
act workflow_dispatch -W .github/workflows/verify-green.yml \
  --input environment=staging --input service=example-service \
  --input collect_mysql_runtime_values=false

# CodeBuild buildspec をローカル実行（手順は ci/codebuild-local-verification.md）
```

`examples/mysql84-parameter-generation/` の入出力は匿名化済みのゴールデンファイルとして機能する。ルール YAML や Ruby 生成器を変更したら再生成して差分をレビューする。

## 編集時の注意

- `.env`、`ci/.act.env`、`aws-config/*`、`global-bundle.pem` は `.gitignore` 済み。`my.cnf` は空プレースホルダとして例外的に追跡しており、実接続情報を書き込んで commit しないよう手順に明記する（必要なら `.env` の `MYSQL_CLIENT_CONFIG_FILE` でリポジトリ外の絶対パスを指す）。ここへ実値を置く手順を書くときは Git 管理しない旨を明記する。
- ドキュメント間の相互参照が密である。Step の分割や実行形態を変えたら `docs/upgrade-flow-steps.md`・`ci/README.md`・`examples/*/README.md`・該当 `docs/phase-*.md` を揃えて更新する。
- コンテナイメージは `latest` を使わない。AWS CLI・MySQL・Ruby はパッチバージョンまで、Go はマイナーまで固定する。**Ruby は `ruby:3.4.10-slim-bookworm` に統一する**（`slim` 以外のバリアントや、パッチを省いた `ruby:3.4` を使わない）。
