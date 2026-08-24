# BuildGreen・VerifyGreen のローカル実行手順

パイプライン（CodePipeline）を使わずに、手元から **BuildGreen（Step 3: 保護スナップショット＋Blue/Green 作成）** と **VerifyGreen（Step 4: 切替前検証）** だけを実行する手順である。切替（Step 5）と後始末（Step 7）は扱わない（[direct-blue-green-execution.md](direct-blue-green-execution.md) を参照）。

パイプラインと同じスクリプト（`scripts/build_green.rb` / `scripts/verify_green.rb`）を `ruby` で直接呼ぶので、結果はパイプラインで実行した場合と同じになる。

## 0. 前提

| 項目 | 内容 |
|---|---|
| 完了していること | Step 1（成立条件チェック）と Step 2（8.4 パラメータグループを CloudFormation で作成）。設定ファイル `config/blue-green/<環境>.yml` に対象サービスが定義されていること |
| 必要なもの | AWS CLI v2、Ruby 3.4。VerifyGreen でビルド済みバイナリを渡さない場合は Go 1.25 も要る。jq・MySQL クライアント・Docker は要らない |
| AWS の権限 | **BuildGreen**: RDS の読み取り（`rds:Describe*`）に加えて `rds:CreateDBSnapshot`・`rds:CreateBlueGreenDeployment`・`rds:CreateDBInstanceReadReplica`・`rds:AddTagsToResource`。移行元が拡張モニタリングを使っていれば、そのロールへの `iam:PassRole` も要る<br>**VerifyGreen**: 読み取りだけ（`rds:Describe*`、`cloudwatch:GetMetricStatistics`）。MySQL 実効値を `parameter_store` で取るなら `ssm:GetParameter` も要る |
| 実行場所 | リポジトリのルート |

パイプラインの準備ステージ（ReadApprovals・BuildReportTool・PrecheckParameterGroup）は要らない。承認の確認とパラメータグループの確認はスクリプト自身が行い、Go のバイナリは必要ならその場でビルドされる（理由は [direct-blue-green-execution.md](direct-blue-green-execution.md) の「パイプラインの準備ステージは要らない」）。

## 1. 共通準備

```bash
export CONFIG_FILE=config/blue-green/staging.yml
export SERVICE_NAME=example-service
export AWS_PROFILE=your-aws-profile        # AWS CLI はこの環境変数のプロファイルを使う
export ARTIFACT_ROOT="artifacts/local/${SERVICE_NAME}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARTIFACT_ROOT"

# 認証先を確認する（読み取りのみ）。意図したアカウントであることを確かめてから進む。
aws sts get-caller-identity
ruby --version
```

リージョンは設定ファイルの `aws_region` を使う。別のリージョンを使う場合だけ、各コマンドに `--region <region>` を足す。

## 2. BuildGreen（Step 3）

### 2-1. 未承認のまま動かして安全を確かめる

設定の `actions.build` が `pending` のままなら、AWS を一切呼ばずに終わる。まずこれで、引数と設定ファイルの読み取りに問題が無いことを確かめる。

```bash
ruby scripts/build_green.rb --config "$CONFIG_FILE" --service "$SERVICE_NAME" \
  --output-dir "$ARTIFACT_ROOT/build-green-dry"
# => build: pending; no changes made.
```

### 2-2. 承認して実行する

設定ファイルの対象サービスで `actions.build` を `approved` にする（レビュー済みの設定変更として扱う）。

```yaml
    actions:
      build: approved
```

```bash
ruby scripts/build_green.rb --config "$CONFIG_FILE" --service "$SERVICE_NAME" \
  --output-dir "$ARTIFACT_ROOT/build-green"
```

スクリプトは次の順に進む。

1. 移行元のエンジンバージョンとパラメータグループを見て、**既に切替済みなら何もせず成功する**（`Migration already completed: ...`）
2. 移行元に対応する Blue/Green Deployment を探す
   - `AVAILABLE` … 既に目的の状態。何もせず成功する
   - `PROVISIONING` … 作成途中。二重に作らず `AVAILABLE` を待つ
   - それ以外（`INVALID_CONFIGURATION` など） … 止める（内容を確認し、不要なら削除してから再実行する）
3. 無ければ作成する。移行元が MySQL 8.0 であること、移行先パラメータグループのファミリーが `mysql8.4` であることを確かめてから、**保護スナップショットを確保**（作成して `available` を待つ）し、Blue/Green Deployment を作成して `AVAILABLE` まで待つ

**最大 60 分待つ。**大きな DB では Green の作成に時間がかかるので、端末を閉じない（途中で切れても、再実行すれば `PROVISIONING` の待機から再開する）。

成功すると次が出る。

```
Green is AVAILABLE. Perform verification before switchover.
Deployment identifier: bgd-xxxxxxxxxxxxxxxx
Artifacts: artifacts/local/.../build-green
```

| 終了コード | 意味 |
|---|---|
| 0 | `AVAILABLE` な Deployment がある（または pending・切替済みで対象なし） |
| 1 | 到達しておらず、自動では到達できない（理由が標準エラーに出る） |
| 2 | 引数の誤り |

`--output-dir` には、各 AWS API の応答（`source-db-instance.json`、`deployments.json`、`target-db-parameter-group.json`、`create-snapshot.json`、`snapshot.json`、`create-blue-green-deployment.json`、`describe-blue-green-deployment.json`）が残る。作業記録として保管する。

実行後は `actions.build` を `pending` に戻してよい（戻しても作成済みの Deployment は消えない）。

## 3. VerifyGreen（Step 4）

読み取りだけで、AWS のリソースを変更しない。承認は要らない。

### 3-1. Go のバイナリ

判定とレポートは Go のバイナリが行う。何も指定しなければ、初回に `.tools/green-report/` へ自動でビルドされる（Go が必要。2 回目以降はビルドキャッシュが効く）。Go の無い端末で動かす場合は、別の端末でビルドしたものを環境変数で渡す。

```bash
# Go のある端末で（実行する端末の OS / CPU に合わせて GOOS / GOARCH を指定する）
CGO_ENABLED=0 go build -o .tools/green-report/generate_green_verification_report ./scripts/generate_green_verification_report
CGO_ENABLED=0 go build -o .tools/green-report/collect_green_runtime_values ./scripts/collect_green_runtime_values

# 実行する端末で
export GREEN_REPORT_GENERATOR="$PWD/.tools/green-report/generate_green_verification_report"
export GREEN_RUNTIME_COLLECTOR="$PWD/.tools/green-report/collect_green_runtime_values"
```

### 3-2. 実行する

```bash
ruby scripts/verify_green.rb --config "$CONFIG_FILE" --service "$SERVICE_NAME" \
  --output-dir "$ARTIFACT_ROOT/verify-green"
```

スクリプトは次の順に進む。

1. 移行元を見て、**既に切替済みなら「検証対象なし」で成功する**（`Already switched over: ...`）
2. Deployment を移行元の ARN で引き当て、`AVAILABLE` であることを確かめる（無い・`AVAILABLE` でなければ止まる）
3. Green のインスタンス・パラメータ（ユーザー／システム／全件）・レプリカ遅延を集めて `--output-dir` へ書く
4. MySQL 実効値を集める（任意。3-3）
5. 判定器が、エンジンバージョン・インスタンスクラス・パラメータグループの関連付けと適用状態・レプリカ遅延・CloudFormation の宣言値と RDS の実値を突き合わせ、レポートを書く

成功すると `VERIFY PASSED: <Deployment ID>`、不適合なら `VERIFY FAILED` と出て終了コード 1 になる。**どちらの場合も** `--output-dir/green-verification-report.md` が残る。不適合の理由はレポートの「0. 検証結果」に載る。

| 終了コード | 意味 |
|---|---|
| 0 | 検証を通った（または切替済みで対象なし） |
| 1 | 不適合、または材料がそろわない（Deployment が無い・`AVAILABLE` でない等） |
| 2 | 引数の誤り |

### 3-3. MySQL 実効値も含める場合（任意）

既定（`mysql_verification.enabled: false`）では Green に接続せず、レポートの「MySQL 実効値」列は `未収集` になる。**判定は AWS API の値で行うので、未収集でも合否は変わらない。**実効値も載せたいときは、設定ファイルで有効にする。

```yaml
    mysql_verification:
      enabled: true
      auth_method: prompt     # ローカルでは対話入力が手軽（エコーしない）
      user: verifier
      port: 3306
```

| `auth_method` | パスワードの取り方 | 備考 |
|---|---|---|
| `prompt` | 実行中に対話入力 | ローカル専用 |
| `parameter_store` | SSM Parameter Store の SecureString（`parameter_name` と `user_parameter_name` の両方が必須） | `ssm:GetParameter` が要る |
| `plaintext` | 設定ファイルの `password` | テスト環境専用。`environment: production` では拒否される |

手元から Green のエンドポイント（3306）へ到達できる必要がある（VPN・踏み台・セキュリティグループ）。TLS は証明書チェーンを検証する（ホスト名は検証しない）。RDS の CA はバイナリに組み込み済みなので、CA ファイルの用意は要らない。パスワードはコマンド引数・成果物に出ない。

### 3-4. 成果物

`--output-dir` に次が残る。レポートはゲート③（切り替えてよいか）の判断材料になるので保管する。

| ファイル | 内容 |
|---|---|
| `green-verification-report.md` | 検証結果とレポート |
| `source.json`・`deployment.json`・`green-db-instance.json` | 移行元・Deployment・Green の応答 |
| `green-user-parameters.json`・`green-system-parameters.json`・`green-all-parameters.json` | Green のパラメータ |
| `replica-lag.json` | レプリカ遅延（CloudWatch） |
| `green-runtime-values.json` | MySQL 実効値（3-3 を有効にしたときだけ） |

## 4. うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| `build: pending; no changes made.` で何も起きない | 設定の `actions.build` が `approved` でない |
| `移行元が移行前・移行後のいずれの宣言とも一致しない` | 設定の `source_engine_version`・`source_db_parameter_group_name`・`target_*` と、移行元の実際の状態が食い違っている。設定を見直す |
| `Blue/Green Deployment exists but is not usable` | 失敗した Deployment が残っている。内容を確認し、不要なら削除して再実行する |
| `Target DB parameter group family must be mysql8.4` | 移行先パラメータグループが未作成か、ファミリーが違う。Step 2 を確認する |
| `AccessDenied`（`create-blue-green-deployment`） | 権限不足。移行元が拡張モニタリングを使っている場合は `iam:PassRole` を確認する |
| `Blue/Green Deployment not found`（VerifyGreen） | BuildGreen が未実行か、別の設定ファイル・リージョンを見ている |
| `... が見つからず、Go も無いのでビルドできない` | 3-1 のとおり、ビルド済みバイナリを環境変数で渡す |
| MySQL 実効値の収集で接続できない | 手元から Green へ到達できない。実効値は任意なので、`enabled: false` に戻せば AWS API だけで検証できる |
