# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの性格

AWS RDS for MySQL 8.0 → 8.4 を Blue/Green Deployments で移行するための、**手順書（Markdown）と実行スクリプトと CI 定義が一体になったリポジトリ**である。アプリケーションコードではなく、テストスイートやビルド成果物も持たない。ドキュメントは日本語で書かれており、追記・修正も日本語で行う。

期限は MySQL 8.0 の標準サポート終了（2026-07-31、8/1 以降は Extended Support が自動課金）であり、`rds-mysql-84-migration-guide.md` が全体の親ドキュメントである。

## 全体アーキテクチャ

### Step 1〜7 の分割

`upgrade-flow-steps.md` が中心的な設計ドキュメントで、移行手順書の Phase 0〜5 を再実行可能な 7 ステップへ割り直している。**新しいスクリプトや CI ジョブを追加するときは、まずこのファイルの分類（実行形態・ワンストップ実行・承認要否）に照らす。**

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
- **本番 DB の認証情報を CI に常設しない。** DB 接続を伴う確認はローカルのコンテナから対話パスワードで行う。CI 側の MySQL 実効値収集（`verify_green.sh` の `--mysql-user`）は既定 `false` の任意機能であり、パスワードは `MYSQL_PWD` として MySQL クライアントのプロセスにだけ渡す。
- **RDS パラメータグループの変更経路は CloudFormation のみ。** Blue/Green Deployment 自体は CFn カスタムリソースを使わず AWS CLI で扱う。
- 破壊的 RDS 権限（`rds:DeleteDBInstance` 等）は CI 実行ロールにのみ付与する。作業者には CloudFormation スタック操作権限だけを与える。

### 設定ファイル

`config/blue-green/{staging,production}.yml` が環境ごとの単一の入力である。全スクリプトが `--config FILE --service NAME` だけを引数に取り、DB 識別子・バージョン・パラメータグループ名・`actions` の承認状態をここから解決する。

`config/mysql80-to-84-parameter-rules.yml` は 8.0 → 8.4 のパラメータ変換ルール（`copy` / `force` / `omit` / `target_only`）を持ち、`generate_mysql84_parameter_group.rb` の唯一のルールソースである。パラメータの扱いを変えるときはスクリプトではなくこの YAML を編集する。

### CI の二系統

同じ `scripts/*.sh` を GitHub Actions と CodeBuild/CodePipeline の両方から実行する。**スクリプトを変更したら両方の呼び出し側を確認する。**

- `.github/workflows/{build-green,verify-green,switchover}.yml` — `workflow_dispatch` のみ。OIDC で `vars.AWS_ROLE_ARN` を引き受ける。`env.ACT` が真のとき（nektos/act）は OIDC ステップを飛ばし、ローカル配置の AWS CLI zip を入れる分岐が入っている。
- `ci/codebuild/*.yml` + `examples/rds-blue-green-deployment/codepipeline.yml` — `BuildGreen → VerifyGreen → ManualApproval → Switchover`。`DetectChanges: false` で push では起動しない。

Step 4 のレポート生成器は Ruby 版（`generate_green_verification_report.rb`、ローカル既定）と Go 版（`generate_green_verification_report.go`、CI が `ci/Dockerfile.green-verification-report` のマルチステージビルドで作り `GREEN_REPORT_GENERATOR` で渡す）が並存する。**両方を同時に更新すること。**

## 実行方法

### 前提

シェルスクリプトは設定 YAML の読み取りにインライン `python3` + PyYAML を使う。ローカルで Step 3〜5 を直接実行する前に一度だけ:

```bash
python3 -m pip install 'PyYAML==6.0.2'
```

AWS CLI・MySQL クライアント・Ruby・Go はローカルインストールせず、`compose.yaml` のコンテナで実行できる（`local-execution.md`）。実接続時だけ `.env` を作り、ホストの `~/.aws`・RDS CA bundle・`my.cnf` を絶対パスで指す。すべて `read_only` マウントである。

```bash
docker compose --env-file .env run --rm awscli sts get-caller-identity
docker compose --env-file .env run --rm ruby scripts/generate_mysql84_parameter_group.rb --help
```

### 各 Step

```bash
# Step 1: 収集 → 判定（STOP が残る間は先へ進まない）
scripts/collect_blue_green_prereqs.sh --db-instance-id <blue-id> --region <region> --profile <profile>
ruby scripts/evaluate_blue_green_prereqs.rb --input-dir <収集先>

# Step 2: 収集 → ルール突合 → レポートと CFn テンプレート生成
scripts/collect_mysql84_parameter_inputs.sh --source-parameter-group <8.0-pg-name>
ruby scripts/generate_mysql84_parameter_group.rb --input-dir <dir> --output-dir <dir> --system <name> --environment <env>

# Step 3〜5（CI と同じエントリポイント。設定が pending なら 3/5 は何もせず正常終了）
scripts/build_green.sh   --config config/blue-green/staging.yml --service example-service
scripts/verify_green.sh  --config config/blue-green/staging.yml --service example-service
scripts/switchover.sh    --config config/blue-green/staging.yml --service example-service --approve
```

### 変更の検証

自動テストはない。代わりに次で確認する。

```bash
# シェル構文チェック
bash -n scripts/*.sh

# Ruby スクリプトの回帰確認（サンプル入力で再生成し、examples/ の出力との差分を見る）
# このサンプルは「要レビュー」が 1 件残るため終了コード 1 が正常
ruby scripts/generate_mysql84_parameter_group.rb \
  --input-dir examples/mysql84-parameter-generation/input \
  --output-dir examples/mysql84-parameter-generation/output \
  --system sample --environment production

# Go レポート生成器
cd scripts && go build ./...

# GitHub Actions をローカル実行（.actrc に AWS profile と絶対パスマウントを設定してから）
act workflow_dispatch -W .github/workflows/verify-green.yml \
  --input environment=staging --input service=example-service \
  --input collect_mysql_runtime_values=false

# CodeBuild buildspec をローカル実行（手順は ci/codebuild-local-verification.md）
```

`examples/mysql84-parameter-generation/` の入出力は匿名化済みのゴールデンファイルとして機能する。ルール YAML や Ruby 生成器を変更したら再生成して差分をレビューする。

## 編集時の注意

- `.env`、`ci/.act.env`、`aws-config/*`、`global-bundle.pem` は `.gitignore` 済み。`my.cnf` は空プレースホルダとして例外的に追跡しており、実接続情報を書き込んで commit しないよう手順に明記する（必要なら `.env` の `MYSQL_CLIENT_CONFIG_FILE` でリポジトリ外の絶対パスを指す）。ここへ実値を置く手順を書くときは Git 管理しない旨を明記する。
- ドキュメント間の相互参照が密である。Step の分割や実行形態を変えたら `upgrade-flow-steps.md`・`ci/README.md`・`examples/*/README.md`・該当 `phase-*.md` を揃えて更新する。
- コンテナイメージは `latest` を使わない。AWS CLI と MySQL はパッチバージョンまで、Ruby と Go はマイナーまで固定する。
