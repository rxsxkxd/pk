# Step 別・実行スクリプトと必要な言語環境

`scripts/` 配下の各スクリプトが Step 1〜7 のどれに対応し、実行にどの言語環境を要求するかをまとめる。Step の内容・分割自体は [upgrade-flow-steps.md](../upgrade-flow-steps.md) を正典とし、本書はそこから見えにくい「実行環境の依存関係」だけを補足する。

## Step 別対応表

| Step | 内容 | エントリポイント | 内部処理／補助 | 言語環境（実行に必要なもの） |
|---|---|---|---|---|
| 1 | 既存インスタンスのチェック | `collect_blue_green_prereqs.sh` | — | Bash + AWS CLI |
| | | `evaluate_blue_green_prereqs.rb` | — | Ruby |
| 2 | パラメータ整理とパラメータグループ生成 | `collect_mysql84_parameter_inputs.sh` | — | Bash + AWS CLI |
| | | `generate_mysql84_parameter_group.rb` | — | Ruby |
| 3 | スナップショット取得と Blue/Green 作成 | `build_green.sh` | → `create_blue_green_deployment.sh`（内部処理） | Bash + AWS CLI + Python3（PyYAML） |
| 4 | Green 構成チェック＋レプリカ同期チェック | `verify_green.sh` | → `collect_green_runtime_values.sh`（補助・任意） | Bash + AWS CLI + Python3（PyYAML）、任意で MySQL クライアント |
| | | `generate_green_verification_report.rb` | ローカル既定 | Ruby |
| | | `generate_green_verification_report.go` | CI 既定（ビルド済みバイナリ） | Go（ビルド時のみ。実行時はバイナリ単体で完結） |
| 5 | Blue/Green 切り替え | `switchover.sh` | → `switchover_blue_green_deployment.sh`（内部処理） | Bash + AWS CLI + Python3（PyYAML） |
| 6 | Green ヘルスチェック | 未実装 | — | — |
| 7 | 後始末 | `cleanup.sh` | — | Bash + AWS CLI + Python3（PyYAML）、任意で MySQL クライアント |

「内部処理」と注記したスクリプトは、対応する外側のエントリポイントから呼ばれる下位スクリプトであり、設定ファイルの `actions:` 承認宣言を見ない。直接実行すると承認ゲートを迂回できてしまう点は [decisions/structure-review-proposal.md](../decisions/structure-review-proposal.md) 論点7で指摘済みで、未対応のまま残っている。

## 言語環境ごとの依存関係

| 言語環境 | 必要な理由 | 対象スクリプト |
|---|---|---|
| Bash | 全エントリポイントの実行シェル。`set -euo pipefail` 前提 | 全 `.sh` ファイル（9 本） |
| AWS CLI | RDS／CloudWatch／CloudFormation の読み取り・変更操作 | Step 1・3・4・5・7 の全 `.sh` |
| Python3 + PyYAML | 設定 YAML（`config/blue-green/*.yml`）の読み込み。`eval "$(python3 -c ...)"` パターンで 1 回だけ呼ばれる | `build_green.sh`、`create_blue_green_deployment.sh`、`verify_green.sh`、`switchover.sh`、`switchover_blue_green_deployment.sh`、`cleanup.sh` |
| Ruby | 判定ロジック（Step 1）・生成ロジック（Step 2）・レポート生成（Step 4 ローカル既定） | `evaluate_blue_green_prereqs.rb`、`generate_mysql84_parameter_group.rb`、`generate_green_verification_report.rb` |
| Go | Step 4 のレポート生成器の CI 版。`ci/Dockerfile.green-verification-report` でマルチステージビルドし、実行時はバイナリ単体（Go ランタイム不要） | `generate_green_verification_report.go`（ビルド時のみ） |
| MySQL クライアント（mysql／mysqlsh） | DB 接続を伴う実効値収集・逆レプリケーション確認。既定ではスキップされ、明示フラグ指定時のみ使用（CI に本番 DB 認証情報を常設しない方針のため） | `collect_green_runtime_values.sh`（Step 4 補助）、`cleanup.sh` の `--mysql-user` 指定時（Step 7） |

## 実行形態（ローカル／CI）との対応

| Step | 実行形態 | 補足 |
|---|---|---|
| 1・2 | ローカル | Bash + AWS CLI + Ruby。コンテナ経由（`compose.yaml`）を推奨 |
| 3・5 | CI | Bash + AWS CLI + Python3。GitHub Actions／CodeBuild ランナーに標準搭載、または `ci/Dockerfile.codebuild-runner`（AWS CLI 2.36.37 + Python 3.14.7） |
| 4 | CI（構成確認）＋ローカル（任意の DB 接続） | レポート生成は CI が Go 版、ローカルが Ruby 版と分岐する |
| 7 | CI（承認付き） | 逆レプリチェックは CI では実行されない。承認前にローカルから `--mysql-user` 付きで手動確認する運用が前提 |

## 補足: Python3 はほぼ全ステップの実質的な必須依存である

Step 3・4・5・7 の `.sh` はいずれも内部で Python3 を 1 回呼び出す構造（設定 YAML 読み込み専用）になっている。これは [reports/inline-python-reduction-report.md](../reports/inline-python-reduction-report.md) で実施した削減対応の結果であり、以前は `python3 -c` が 38 箇所に散在していたものを、各スクリプト 1 箇所（YAML 読み込み）まで絞り込んだ。「AWS CLI さえあれば Bash だけで動く」わけではなく、**Python3 + PyYAML が実質的に必須の依存**である点に注意する。jq／yq のような外部ツールは意図的に導入していない（`decisions/structure-review-proposal.md` 論点1を参照）。
