# Step 別・実行スクリプトと必要な言語環境

`scripts/` 配下の各スクリプトが Step 1〜7 のどれに対応し、実行にどの言語環境を要求するかをまとめる。Step の内容・分割自体は [upgrade-flow-steps.md](../upgrade-flow-steps.md) を正典とし、本書はそこから見えにくい「実行環境の依存関係」だけを補足する。

## Step 別対応表

| Step | 内容 | エントリポイント | 内部処理／補助 | 言語環境（実行に必要なもの） |
|---|---|---|---|---|
| 1 | 既存インスタンスのチェック | `collect_blue_green_prereqs` | — | Bash + AWS CLI |
| | | `evaluate_blue_green_prereqs` | — | Go |
| 2 | パラメータ整理とパラメータグループ生成 | `collect_mysql84_parameter_inputs` | — | Bash + AWS CLI |
| | | `generate_mysql84_parameter_group` | — | Go |
| 3 | スナップショット取得と Blue/Green 作成 | `build_green.sh` | → `create_blue_green_deployment.rb`（内部処理） | Bash + AWS CLI + Ruby + jq |
| 4 | Green 構成チェック＋レプリカ同期チェック | `verify_green.sh` | → `collect_green_state.rb`（AWS の状態収集）、→ `collect_green_runtime_values.rb`（DB 実効値の収集。補助・任意）、→ `generate_green_verification_report`（Go。判定とレポート生成、内部処理） | Bash + AWS CLI + Ruby + jq、任意で MySQL クライアントと Go |
| 5 | Blue/Green 切り替え | `switchover.sh` | → `switchover_blue_green_deployment.rb`（内部処理） | Bash + AWS CLI + Ruby + jq |
| 6 | Green ヘルスチェック | 未実装 | — | — |
| 7 | 後始末 | `cleanup`（`tools/cleanup/`） | — | Go + AWS CLI、任意で MySQL クライアント |

「内部処理」と注記したスクリプトは、対応する外側のエントリポイントから呼ばれる下位スクリプトであり、設定ファイルの `actions:` 承認宣言を見ない。直接実行すると承認ゲートを迂回できてしまう点は [decisions/structure-review-proposal.md](../decisions/structure-review-proposal.md) 論点7で指摘済みで、未対応のまま残っている。

### Step 4 のレポート生成器: `verify_green.sh` による呼び分け

Step 4 のレポート生成器は **Go 版だけ**である。`verify_green.sh` は事前ビルド済みのバイナリを受け取るか、無ければ自分でビルドする。

```bash
# scripts/verify_green.sh
report_generator=${GREEN_REPORT_GENERATOR:-}
if [[ -z "$report_generator" ]]; then
  go -C "$repository_root" build -o "$report_generator" ./scripts/generate_green_verification_report
fi
```

| 実行環境 | `GREEN_REPORT_GENERATOR` | ビルド方法 |
|---|---|---|
| ローカル（未指定） | 未設定 | `verify_green.sh` が一時ファイルへビルドする（Go が必要） |
| CodeBuild | `.tools/green-report/...` を指定 | buildspec が `runtime-versions: golang` + `go build`（`scripts/` 配下の 2 コマンド） |
| GitHub Actions | `.tools/green-report/...` を指定 | workflow が `go build ./scripts/generate_green_verification_report`（Docker は使わない） |

**どの経路も同じ 1 バイナリである。**MySQL 実効値（`--runtime-values`）は任意で、渡さなければレポートの該当列が `未収集` になるだけである。

## 言語環境ごとの依存関係

| 言語環境 | 必要な理由 | 対象スクリプト |
|---|---|---|
| Bash | 全エントリポイントの実行シェル。`set -euo pipefail` 前提 | 全 `.sh` ファイル（9 本） |
| AWS CLI | RDS／CloudWatch／CloudFormation の読み取り・変更操作 | Step 1・3・4・5・7 の全 `.sh` |
| Ruby（標準ライブラリのみ） | `scripts/` 側の**設定 YAML の読み取り**とフェーズ判定・Blue/Green の作成と切替。実体は `scripts/lib/deployment_config.rb` の 1 箇所のみで、シェルからはコマンドとして呼んで代入行を受け取る。**gem の追加導入は無い（psych / json は標準ライブラリ）。新しいプログラムは Ruby で書かない** | `evaluate_blue_green_prereqs`、`generate_mysql84_parameter_group`、および設定を読む全 `.sh`（`scripts/lib/deployment_config.rb` 経由） |
| Go | **新しいプログラムは Go で書く**（`decisions/implementation-language-policy.md`）。現状は Step 4 のレポート生成、RDS インベントリ収集、Blue/Green 設定とレビューレポートの生成、CloudFormation テンプレートの読み取り。ビルド時のみ Go が必要で、実行時はバイナリ単体（ランタイム不要） | `generate_green_verification_report/`（Step 4 内部処理。単体では叩かず、`verify_green.sh` が `GREEN_REPORT_GENERATOR` 経由で呼ぶ）、`collect_green_runtime_values/`（Green DB の実効値収集。MySQL クライアントの代替）、`collect_rds_instance_inventory/`（Step 3 の前準備。内部で AWS CLI を呼ぶ）、`generate_blue_green_config/`（同じく Step 3 の前準備。AWS を呼ばない）、`generate_blue_green_config_report/`（同じ入力からレビュー用 Markdown を出す。設定ファイルは書き換えない）。いずれも `go run ./scripts/<コマンド名>` で実行し（`go.mod` はリポジトリ直下にあるため、引数の相対パスは実行時のカレントディレクトリ基準になる）、ロジックは `tools/internal/{common,collect,generate,cfn,report}` にある（`go test ./...` で単体テスト可能） |
| jq | **JSON の読み取り・生成**。AWS CLI 応答からの値取り出し、MySQL の `--batch` 出力の JSON 化（設定 YAML の読み取りには使わない） | `check_target_parameter_group.rb`、`create_blue_green_deployment.sh`、`collect_green_runtime_values.sh` |
| MySQL クライアント（mysql／mysqlsh） | DB 接続を伴う実効値収集・逆レプリケーション確認。既定ではスキップされ、明示フラグ指定時のみ使用（CI に本番 DB 認証情報を常設しない方針のため） | `collect_green_runtime_values.sh`（Step 4 補助）、`tools/cleanup` の `--mysql-user` 指定時（Step 7） |

## 実行形態（ローカル／CI）との対応

| Step | 実行形態 | 補足 |
|---|---|---|
| 1・2・7 | ローカル | Go + AWS CLI（MySQL 側の確認は mysql / mysqlsh）。コンテナ経由（`compose.yaml`）を推奨 |
| 3・5 | CI | Bash + AWS CLI + Ruby + jq。CodeBuild は install フェーズの `rbenv local 3.4.10`、GitHub Actions はランナー同梱の Ruby、Local Agent は `ci/Dockerfile.codebuild-runner`（AWS CLI 2.36.37 + Ruby 3.4.10 + jq） |
| 4 | CI（構成確認）＋ローカル（DB 接続を伴う確認） | **リモートで MySQL へ到達できない構成もありうる**（VPC 構成が別途必要）。その場合は MySQL 接続とレポート出力をローカルで完結させる。レポート生成器は同じプログラムで、`--runtime-values` の有無だけが違う。詳細は [decisions/implementation-language-policy.md](../decisions/implementation-language-policy.md) |
| 7 | CI（承認付き） | 逆レプリチェックは CI では実行されない。承認前にローカルから `--mysql-user` 付きで手動確認する運用が前提 |

## 補足: Python は使わない。YAML は Ruby、その他は jq

**シェルスクリプトから Python を呼ばない方針である。**Step 3・4・5・7 の `.sh` はいずれも設定 YAML を 1 回読むが、**その読み取りは `scripts/lib/deployment_config.rb` に集約されている**。各スクリプトは取り出す項目だけを宣言し、代入行を受け取って `eval` する。

```bash
config_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
  build=optional:service.actions.build=pending \
  config_region=required:aws_region)
eval "$config_vars"
```

必須・任意の判定と、`mysql_verification` の検証（`mysql-verification` サブコマンド）も同ファイルが行う。

経緯は次のとおりである。以前は `python3 -c` が 38 箇所に散在し（[auxiliary/inline-python-reduction-report.md](../../auxiliary/inline-python-reduction-report.md)）、その後スクリプトごとに 1 箇所ずつ計 9 箇所・206 行まで絞り込み、2026-09-14 に 1 箇所へ統合したうえで Ruby へ切り替えた。その後、jq で行っていた取り出しと検証も Ruby へ移し、設定の読み取りから jq を外した。

**Ruby を選んだ理由は、YAML と JSON がどちらも標準ライブラリ（psych / json）だからである。**PyYAML のような追加パッケージの導入が不要になり、CI から **PyPI への到達要件が消えた**。CodeBuild では各 buildspec が install フェーズで `rbenv local 3.4.10` を実行して Ruby を選ぶ（image 同梱の rbenv を使う）。

**「AWS CLI さえあれば Bash だけで動く」わけではない。**Ruby と jq が実質的に必須の依存である点は変わらない。yq は引き続き導入していない。
