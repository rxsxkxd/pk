# Step 別・実行スクリプトと必要な言語環境

各エントリポイントが Step 1〜7 のどれに対応し、実行にどの言語環境を要求するかをまとめる。Step の内容・分割自体は [upgrade-flow-steps.md](../upgrade-flow-steps.md) を正典とし、本書はそこから見えにくい「実行環境の依存関係」だけを補足する。

## Step 別対応表

| Step | 内容 | エントリポイント | 内部で使うもの | 言語環境（実行に必要なもの） |
|---|---|---|---|---|
| 1 | 既存インスタンスのチェック | `tools/collect_blue_green_prereqs` | — | Go + AWS CLI（MySQL 側は mysql / mysqlsh） |
| | | `tools/evaluate_blue_green_prereqs` | — | Go |
| 2 | パラメータ整理とパラメータグループ生成 | `tools/collect_mysql84_parameter_inputs` | — | Go + AWS CLI |
| | | `tools/generate_mysql84_parameter_group` | — | Go |
| 3 | スナップショット取得と Blue/Green 作成 | `scripts/build_green.rb` | `lib/migration_phase.rb`（フェーズガード） | Ruby + AWS CLI |
| 4 | Green 構成チェック＋レプリカ同期チェック | `scripts/verify_green.rb` | `lib/migration_phase.rb`・`lib/green_state.rb`（AWS の状態収集）、`collect_green_runtime_values.rb` → Go の収集器（DB 実効値。任意）、Go の `generate_green_verification_report`（判定とレポート） | Ruby + AWS CLI + Go バイナリ 2 本 |
| 5 | Blue/Green 切り替え | `scripts/switchover.rb` | `lib/migration_phase.rb`（フェーズガード） | Ruby + AWS CLI |
| 6 | Green ヘルスチェック | 未実装 | — | — |
| 7 | 後始末 | `tools/cleanup` | — | Go + AWS CLI、任意で MySQL クライアント |

Step 3〜5 のエントリポイントは、設定ファイルの `actions:` 承認宣言を自分で読み、`approved` でなければ AWS を呼ばずに終わる。承認ゲートを迂回する「内部処理だけの下位スクリプト」は無い。

CodeBuild・GitHub Actions からは `ruby scripts/<名前>.rb` の形で呼ぶ（CodePipeline の artifact で実行ビットが落ちうるため。`tests/ruby_invocation_test.sh`）。

### Step 4 のバイナリ: `verify_green.rb` による呼び分け

Step 4 の判定器（`generate_green_verification_report`）と実効値の収集器（`collect_green_runtime_values`）は Go である。場所は `scripts/lib/resolve_green_tools.rb` が決める。

| 実行環境 | 環境変数 | ビルド方法 |
|---|---|---|
| ローカル（未指定） | 未設定 | `verify_green.rb` が `.tools/green-report/` へビルドする（Go が必要） |
| CodeBuild | `GREEN_REPORT_GENERATOR` / `GREEN_RUNTIME_COLLECTOR` | BuildReportTool（`build-report-tool.yml`）がビルドし、artifact で渡す。VerifyGreen はビルドしない |
| GitHub Actions | 同上 | workflow が `go build` する（Docker は使わない） |

MySQL 実効値（`--runtime-values`）は任意で、渡さなければレポートの該当列が `未収集` になるだけである。

## 言語環境ごとの依存関係

| 言語環境 | 必要な理由 | 対象 |
|---|---|---|
| Ruby（標準ライブラリのみ） | パイプラインの **AWS 操作**（AWS CLI を exec。SDK は使わない）と**設定 YAML の読み取り**（`scripts/lib/deployment_config.rb` の 1 か所）。gem の追加導入は無い | `scripts/*.rb`・`scripts/lib/*.rb` |
| Go | 人が実行するツール一式と、パイプラインの **MySQL クエリ**・判定・レポート。ビルド時のみ Go が必要で、実行時はバイナリ単体 | `tools/`、`scripts/generate_green_verification_report/`・`scripts/collect_green_runtime_values/` |
| AWS CLI | RDS／CloudWatch の読み取り・変更操作 | Step 1・2・3・4・5・7 |
| MySQL クライアント（mysql／mysqlsh） | Step 1 の MySQL 側の確認と、Step 7 の逆レプリケーション確認。パイプラインでは使わない（実効値収集は Go バイナリ） | `tools/collect_blue_mysql_state`・`tools/collect_blue_upgrade_check`・`tools/cleanup` |
| Bash | BuildReportTool のモジュールルート検査だけ。Ruby を持たない `golang:1.25` イメージでもローカル検証できるようにするため | `scripts/resolve_go_module_root.sh` |

jq と Python は使わない。

## 実行形態（ローカル／CI）との対応

| Step | 実行形態 | 補足 |
|---|---|---|
| 1・2・7 | ローカル | Go + AWS CLI（MySQL 側の確認は mysql / mysqlsh）。コンテナ経由（`compose.yaml`）を推奨 |
| 3・5 | CI | Ruby + AWS CLI。CodeBuild は install フェーズの `rbenv local 3.4.10`、GitHub Actions はランナー同梱の Ruby、Local Agent は `ci/Dockerfile.codebuild-runner` |
| 4 | CI（構成確認）＋ローカル（DB 接続を伴う確認） | **リモートで MySQL へ到達できない構成もありうる**（VPC 構成が別途必要）。その場合は MySQL 接続とレポート出力をローカルで完結させる。判定器は同じプログラムで、`--runtime-values` の有無だけが違う。詳細は [decisions/implementation-language-policy.md](../decisions/implementation-language-policy.md) |

## 補足: YAML は Ruby で読む

設定 YAML の読み取りは `scripts/lib/deployment_config.rb` に集約されている。Ruby からは `require_relative` して使う。buildspec から読む場合（`read-approvals.yml`）は、取り出す項目を宣言して代入行を受け取り、変数へ受けてから `eval` する。

```bash
approvals=$(ruby scripts/lib/deployment_config.rb vars "$CONFIG_FILE" "$SERVICE_NAME" \
  BUILD_APPROVED=optional:service.actions.build=pending \
  SWITCHOVER_APPROVED=optional:service.actions.switchover=pending)
eval "$approvals"
```

経緯: 以前は `python3 -c` が 38 箇所に散在していた（[auxiliary/inline-python-reduction-report.md](../../auxiliary/inline-python-reduction-report.md)）。1 箇所へ統合したうえで Ruby へ切り替え、その後 jq で行っていた取り出しも Ruby へ移した。さらに Step 3〜5 のシェルのエントリポイントを Ruby へ移したので、パイプラインにシェルスクリプトはほぼ残っていない。

**Ruby を選んだ理由は、YAML と JSON がどちらも標準ライブラリ（psych / json）だからである。**追加パッケージの導入が不要で、CI から PyPI への到達要件も無い。
