# Blue/Green 移行スクリプトの直接実行手順

本書は、CodeBuild Local Agent を使わずに `scripts/*.sh` を直接実行して、RDS for MySQL 8.0 から 8.4 への Blue/Green 移行を進める手順である。

CodeBuild Local Agent の buildspec 互換性確認は [ci/codebuild-local-verification.md](ci/codebuild-local-verification.md) を参照する。本書は実運用の直接実行に必要な順序・安全ゲート・コマンドを対象とする。

## 1. 対象範囲と実行順序

Step 1・2（事前確認、パラメータグループ生成・CloudFormation 適用）は、先に [phase-0-precheck.md](phase-0-precheck.md) と [phase-1-parameter-group-cloudformation.md](phase-1-parameter-group-cloudformation.md) に従って完了させる。本書は、CloudFormation が移行先の MySQL 8.4 DB パラメータグループを作成済みである時点から開始する。

```text
CloudFormation で 8.4 パラメータグループを作成済み
  │
  ├─ 1. target parameter group の事前確認（読み取りのみ）
  ├─ 2. BuildGreen: 保護スナップショット + Blue/Green 作成（変更）
  ├─ 3. VerifyGreen: Green 設定 + ReplicaLag 検証（読み取りのみ）
  ├─ 4. アプリケーション・DB 接続・性能検証（手動）
  ├─ 5. Switchover（変更・本番影響）
  ├─ 6. 切替後のアプリケーション・監視確認（手動）
  └─ 7. Cleanup（変更・旧 Blue 削除）
```

`create_blue_green_deployment.sh` と `switchover_blue_green_deployment.sh` は、それぞれ `build_green.sh` と `switchover.sh` の内部実装である。通常運用では直接実行せず、上位スクリプトを入口とする。

## 2. 共通準備

リポジトリのルートで実行する。直接実行には Bash、AWS CLI v2、Ruby、jq、GNU `date` が必要である。`verify_green.sh` は `date -d` を使うため、macOS の標準 `date` だけでは動作しない。Linux 環境または GNU coreutils を提供するコンテナで実行する。

```bash
export CONFIG_FILE=config/blue-green/staging.deployment.yml
export SERVICE_NAME=example-service
export AWS_PROFILE=your-aws-profile
export ARTIFACT_ROOT="artifacts/direct/${SERVICE_NAME}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARTIFACT_ROOT"

# AWS の認証先・実行対象を確認する（読み取りのみ）。
aws sts get-caller-identity --profile "$AWS_PROFILE"

# シェルスクリプトが設定 YAML を読むために必要。
# 設定 YAML の読み取りは Ruby の標準ライブラリで行う（追加導入は不要）。
ruby --version
# JSON の読み取りに jq を使う。無い場合は該当スクリプトが起動直後に停止する。
jq --version
```

`CONFIG_FILE` の `aws_region` を既定で使用する。別リージョンを使う場合だけ、各コマンドに `--region <region>` を追加する。

変更操作を行う Step 2、5、7 は、設定ファイルの `actions` による承認が必要である。

```yaml
actions:
  build: pending          # Step 2 を実行する直前だけ approved
  switchover: pending     # Step 5 を実行する直前だけ approved
  switchover_timeout: 300
  cleanup: pending        # Step 7 を実行する直前だけ approved
```

`pending` のまま上位スクリプトを実行すると、変更せず正常終了する。承認値の変更は、レビュー済みの設定変更として管理する。

## 3. Step 1 相当: 移行先パラメータグループの事前確認

CloudFormation で作成済みの `target_db_parameter_group_name` がリモートに存在し、目標エンジンバージョンに対応する family（例: `mysql8.4`）であることを確認する。

```bash
scripts/check_target_parameter_group.sh \
  --config "$CONFIG_FILE" \
  --service "$SERVICE_NAME" \
  --profile "$AWS_PROFILE" \
  --output-dir "$ARTIFACT_ROOT/01-parameter-group-precheck"
```

このスクリプトが呼ぶ AWS API は `rds describe-db-parameter-groups` だけであり、変更操作は行わない。次の成果物を確認する。

- `target-db-parameter-group.json`: RDS が返したパラメータグループ情報
- `target-parameter-group-check.md`: 名前・family の判定結果

失敗時は Step 2 へ進まず、CloudFormation スタック、環境設定の名前、または目標エンジンバージョンを修正する。

## 4. Step 2 相当: BuildGreen

### 4-1. 未承認状態の安全確認

最初に `actions.build: pending` のまま実行する。保護スナップショット作成・Blue/Green 作成が行われないことを確認する。

```bash
scripts/build_green.sh \
  --config "$CONFIG_FILE" \
  --service "$SERVICE_NAME" \
  --profile "$AWS_PROFILE" \
  --output-dir "$ARTIFACT_ROOT/02-build-green-pending"
```

`build: pending; no changes made.` が出力されれば安全ゲートは正常である。

### 4-2. Green の作成

Step 1・2 のレビューが完了し、保護スナップショットと Green を作成してよい時点で、対象サービスの `actions.build` を `approved` に変更する。その後、同じコマンドを実行する。

```bash
scripts/build_green.sh \
  --config "$CONFIG_FILE" \
  --service "$SERVICE_NAME" \
  --profile "$AWS_PROFILE" \
  --output-dir "$ARTIFACT_ROOT/02-build-green"
```

この処理は次を行う。

1. 同じ Source の既存 Blue/Green deployment がないことを確認する。
2. 保護スナップショットがなければ作成し、`available` まで待機する。
3. 移行元が MySQL 8.0、移行先パラメータグループが `mysql8.4` であることを確認する。
4. 指定済みの DB インスタンスクラス・エンジンバージョン・パラメータグループで Green を作成する。
5. deployment が `AVAILABLE` になるまで待機する。

Green 作成中・作成後も、切替は実行しない。`AVAILABLE` を確認して Step 3 へ進む。

## 5. Step 3 相当: VerifyGreen

`verify_green.sh` は、Green のエンジンバージョン、DB インスタンスクラス、関連付けパラメータグループ、`Source=user` 値、`ReplicaLag` を確認し、Markdown レポートを出力する。

### 5-1. レポート生成器

レポート生成器は Go 版だけである。**`GREEN_REPORT_GENERATOR` を指定しなければ `verify_green.sh` が一時ファイルへビルドして使う**ため、通常は何も用意しなくてよい（Go が必要）。

```bash
scripts/verify_green.sh \
  --config "$CONFIG_FILE" \
  --service "$SERVICE_NAME" \
  --profile "$AWS_PROFILE" \
  --output-dir "$ARTIFACT_ROOT/03-verify-green"
```

繰り返し実行するなら、CI と同じようにバイナリを作って渡す方が速い。

```bash
go build -o .tools/green-report/generate_green_verification_report ./scripts/generate_green_verification_report

GREEN_REPORT_GENERATOR="$PWD/.tools/green-report/generate_green_verification_report" \
  scripts/verify_green.sh \
    --config "$CONFIG_FILE" \
    --service "$SERVICE_NAME" \
    --profile "$AWS_PROFILE" \
    --output-dir "$ARTIFACT_ROOT/03-verify-green"
```

判定が成功した場合でも、アプリケーション検証を完了するまで Step 5 へ進まない。失敗時は `green-verification-report.md` と収集済み JSON を確認し、Green の作り直しまたは設定修正を判断する。

### 5-2. MySQL 実効値を含める場合

`mysql_verification.enabled: true` にすると、`verify_green.sh` が Green DB へ接続して実効値を収集し、同じレポートの「MySQL 実効値」列を埋める。**リモート（CodeBuild）では VPC 構成が別途必要になるため、この確認はローカルから行う運用を想定している**（[decisions/implementation-language-policy.md](decisions/implementation-language-policy.md)）。実効値なしでもレポートは出力され、判定内容は変わらない。

### 5-3. MySQL 実効値をレポートへ加える場合

Green DB に接続可能な場所から、認証情報を環境変数で渡して実行する。MySQL 実効値はレポートへ掲載するが、YAML・`Source=user` との一致判定には使用しない。

```bash
read -rs -p 'Green DB password: ' MYSQL_PASSWORD; echo
export MYSQL_PASSWORD

GREEN_REPORT_GENERATOR="$PWD/.tools/green-report/generate_green_verification_report" \
  scripts/verify_green.sh \
    --config "$CONFIG_FILE" \
    --service "$SERVICE_NAME" \
    --profile "$AWS_PROFILE" \
    --mysql-user your-db-user \
    --mysql-password-env MYSQL_PASSWORD \
    --output-dir "$ARTIFACT_ROOT/03-verify-green-runtime"
unset MYSQL_PASSWORD
```

TLS CA を指定した MySQL 実効値収集が必要な場合は、先に `collect_green_runtime_values.sh --help` を確認して収集結果 JSON を作成し、`verify_green.sh --runtime-values-file <file>` を使う。

## 6. Step 4 相当: 切替前の人手検証

この段階では切替を実行しない。少なくとも次を確認し、結果を change record に残す。

- Green へのアプリケーション接続、主要な読み書き処理、ジョブ・バッチの疎通
- 性能の代表クエリと実行計画、エラー率、CPU、メモリ、ストレージ、`ReplicaLag`
- スロークエリログ・一般ログを一時的に有効化している場合の設定と出力量
- 切替時の接続断、許容停止時間、切替後の監視・切戻し判断の担当者

## 7. Step 5 相当: Switchover

### 7-1. 未承認状態の安全確認

`actions.switchover: pending` のまま、必ず `--approve` を付けて実行する。`--approve` は CLI の安全ゲート、`actions.switchover` は設定上の安全ゲートであり、両方が必要である。

```bash
scripts/switchover.sh \
  --config "$CONFIG_FILE" \
  --service "$SERVICE_NAME" \
  --profile "$AWS_PROFILE" \
  --approve \
  --output-dir "$ARTIFACT_ROOT/05-switchover-pending"
```

`switchover: pending; no changes made.` が出力されれば、切替は行われていない。

### 7-2. 切替の実行

切替前の検証完了を承認した後にのみ `actions.switchover` を `approved` に変更し、同じコマンドを実行する。

```bash
scripts/switchover.sh \
  --config "$CONFIG_FILE" \
  --service "$SERVICE_NAME" \
  --profile "$AWS_PROFILE" \
  --approve \
  --output-dir "$ARTIFACT_ROOT/05-switchover"
```

この処理は `AVAILABLE` の deployment だけを対象に `switchover-blue-green-deployment` を呼ぶ。本番接続の断続・切替タイムアウトを監視する。

## 8. Step 6 相当: 切替後の確認

現在、切替後ヘルスチェックを一括実行する専用スクリプトはない。切替直後と観測期間中に、次を人手で確認する。

- 既存エンドポイント経由で新 Green に接続でき、書込み可能であること
- アプリケーションのエラー率、レイテンシ、ジョブ、バッチ、外部連携
- CloudWatch の CPU、メモリ、ストレージ、接続数、ログ、Performance Insights / Database Insights
- ロールバックまたは旧 Blue 保持期間の判断

この確認が終わるまで `actions.cleanup` は `pending` のままとする。

## 9. Step 7 相当: Cleanup

後始末は Blue/Green deployment と旧 Blue（`<source>-old1`）を削除する不可逆操作である。実行前に、旧 Blue の保持期間・最終スナップショット・逆方向レプリケーションが不要であることを承認する。

### 9-1. 未承認状態の安全確認

```bash
scripts/cleanup.sh \
  --config "$CONFIG_FILE" \
  --service "$SERVICE_NAME" \
  --profile "$AWS_PROFILE" \
  --output-dir "$ARTIFACT_ROOT/07-cleanup-pending"
```

`cleanup: pending; no changes made.` が出力されれば削除されない。

### 9-2. 削除の実行

切戻し経路を破棄してよいと承認した後、`actions.cleanup` を `approved` に変更して実行する。

```bash
read -rs -p 'Old Blue DB password: ' MYSQL_PASSWORD; echo
export MYSQL_PASSWORD

scripts/cleanup.sh \
  --config "$CONFIG_FILE" \
  --service "$SERVICE_NAME" \
  --profile "$AWS_PROFILE" \
  --mysql-user your-db-user \
  --mysql-password-env MYSQL_PASSWORD \
  --ssl-ca /path/to/global-bundle.pem \
  --output-dir "$ARTIFACT_ROOT/07-cleanup"
unset MYSQL_PASSWORD
```

この処理は `SWITCHOVER_COMPLETED`、旧 Blue の削除保護、旧 Blue の逆方向レプリケーション停止を確認してから、deployment の削除と旧 Blue の最終スナップショット付き削除を開始する。`--mysql-user` を省略すると逆方向レプリケーション確認をスキップして警告だけを出すため、削除実行では指定することを推奨する。成果物の `delete-*.json` と最終スナップショット識別子を保存する。

## 10. 収集スクリプト・内部スクリプトの扱い

| スクリプト | 直接実行する場面 |
| --- | --- |
| `collect_blue_green_prereqs.sh` | Step 1 の事前棚卸し。一括収集や個別の読み取り確認は [tools/README.md](tools/README.md) を参照。 |
| `collect_mysql84_parameter_inputs.sh` | Step 2 のパラメータグループ生成入力の収集。Phase 1 手順書を参照。 |
| `check_target_parameter_group.sh` | 本書の Step 1。BuildGreen の直前に実行。 |
| `build_green.sh` | 本書の Step 2 の入口。内部で `create_blue_green_deployment.sh` を呼ぶ。 |
| `verify_green.sh` | 本書の Step 3 の入口。必要に応じて `collect_green_runtime_values.sh` を呼ぶ。 |
| `switchover.sh` | 本書の Step 5 の入口。内部で `switchover_blue_green_deployment.sh` を呼ぶ。 |
| `cleanup.sh` | 本書の Step 7 の入口。 |

## 11. 実行後に保管するもの

`ARTIFACT_ROOT` 以下の JSON・Markdown を、実行日時・実行者・設定ファイルの Git revision とともに保管する。特に、次のファイルは次ステップの承認根拠となる。

- Step 1: `target-parameter-group-check.md`
- Step 2: `source.json`、`snapshot.json` / `create-snapshot.json`、`create-blue-green-deployment.json`
- Step 3: `green-verification-report.md`、`green-db-instance.json`、`replica-lag.json`
- Step 5: `before-switchover.json`、`switchover-blue-green-deployment.json`
- Step 7: `deployment.json`、`old-blue.json`、`delete-blue-green-deployment.json`、`delete-db-instance.json`
