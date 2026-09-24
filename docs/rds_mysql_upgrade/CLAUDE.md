# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの性格

AWS RDS for MySQL 8.0 → 8.4 を Blue/Green Deployments で移行するための、**手順書（Markdown）と実行スクリプトと CI 定義が一体になったリポジトリ**である。アプリケーションコードではなく、テストスイートやビルド成果物も持たない。ドキュメントは日本語で書かれており、追記・修正も日本語で行う。

期限は MySQL 8.0 の標準サポート終了（2026-07-31、8/1 以降は Extended Support が自動課金）であり、`docs/rds-mysql-84-migration-guide.md` が全体の親ドキュメントである。

## 全体アーキテクチャ

### Step 1〜7 の分割

**実運用の手順は 2 本に集約してある。**`operations-environment-setup.md`（環境構築。CloudFormation でパイプラインを作るまで。一度だけ）と `operations-migration-run.md`（移行の実行。成立条件チェック・設定生成からパイプラインでの移行まで。対象ごとに繰り返す）である。**オペレーション手順を書き足すときは、まずこの 2 本のどちらかに属するかを考える。**個々のチェックの中身や背景は補足ドキュメント側に置き、2 本からはリンクする。

**チェックは 3 種類あり、「事前チェック」「事前確認」とひとまとめに呼ばない。**パイプライン前にローカルで行う **成立条件チェック**（Step 1。ゲート①）、パイプライン中で Blue/Green を作る直前の **構築前チェック**（ステージ `PrecheckParameterGroup`。移行先パラメータグループの存在と family）、Blue/Green 作成後・切替前の **切替前検証**（ステージ `VerifyGreen`。Step 4。ゲート③）である。定義は `operations-migration-run.md` の「チェックの呼び分け」。`precheck` を含むリソース名・ファイル名は既存のまま残しており、`docs/phase-0-precheck.md` は成立条件チェック、`PrecheckParameterGroup` は構築前チェックを指す。

`docs/upgrade-flow-steps.md` が中心的な設計ドキュメントで、移行手順書の Phase 0〜5 を再実行可能な 7 ステップへ割り直している。**新しいスクリプトや CI ジョブを追加するときは、まずこのファイルの分類（実行形態・ワンストップ実行・承認要否）に照らす。**

| Step | 内容 | 実行形態 | エントリポイント |
|---|---|---|---|
| 1 | 既存 Blue の成立条件チェック | ローカル | `collect_blue_green_prereqs.sh` → `evaluate_blue_green_prereqs.rb` |
| 2 | 8.4 パラメータグループの整理・生成・CFn 適用 | ローカル | `collect_mysql84_parameter_inputs.sh` → `generate_mysql84_parameter_group.rb` |
| 3 | 保護スナップショット＋Blue/Green 作成 | CI | `build_green.sh` → `create_blue_green_deployment.rb` |
| 4 | Green 構成・レプリカ同期の検証 | CI | `verify_green.sh` |
| 5 | 切替 | CI（承認付き） | `switchover.sh` → `switchover_blue_green_deployment.rb` |
| 6 | Green ヘルスチェック | CI（AWS API）＋ローカル（DB 接続） | 未実装 |
| 7 | 後始末（旧 Blue 削除） | **ローカル（ツール）** | `tools/cleanup.sh`（パイプラインからは外した） |

### 設計上の中核ルール

これらは既存コードの随所に埋め込まれている。逸脱する変更を入れない。

- **収集と判定を分離する。** シェルスクリプトは AWS CLI の読み取り API（`Describe*`／`Get*`）で JSON を `--output-dir` に落とすだけ、判定は AWS を呼ばない Ruby／Go／インライン Python が行う。変更操作を行う行には `# [変更]` のコメントが付いている。
- **判定系は不適合時に終了コード `1` を返す。** CI のジョブ失敗としてそのまま扱う（例: `generate_mysql84_parameter_group.rb` は「要レビュー」が残ると `1`）。
- **宣言と実環境の突き合わせ（reconciliation）。** 設定ファイルは進捗の記録ではなく「このアクションを実行してよい」という人間の宣言（`pending` / `approved`）を持つ。CI は毎回 AWS の実状態を読み、未適用なら適用、適用済みなら何もしない。**CI が設定ファイルへ書き戻すことはしない。** `approved` → `pending` に戻しても適用済みのものは取り消さない。
- **識別子は AWS から引き当てる。** Deployment ID を設定ファイルに持たず、`describe-blue-green-deployments --filters Name=source,Values=$source_arn` で毎回解決する。これにより再実行・リトライ・同時トリガーで二重作成・二重切替が起こらない。
- **冪等性は二層で担保する。** ① 移行元インスタンスのエンジンバージョンとパラメータグループで「結果」を観測し（**実装は `scripts/lib/migration_phase.rb` の 1 本**。シェルの呼び出し側 4 本は `ruby scripts/lib/migration_phase.rb resolve ...` を直接呼ぶ。以前あったシェルの委譲ラッパー `migration_phase.sh` は廃止した）、② Deployment の `Status` を安全弁として併用する。切替時に blue が `-old1` へリネームされるため、`source_db_instance_identifier` が指す実体は切替の前後で変わる。この判定は Deployment が cleanup で削除された後も機能する。**終了コードは「操作を実行したか」ではなく「望ましい終了状態に到達しているか」で決める**（到達 = `0`、未到達かつ自動では到達不能 = `1`）。設計の背景は `decisions/idempotency-strategy.md`。
- **本番 DB の認証情報を CI に常設しない。** DB 接続を伴う確認はローカルのコンテナから対話パスワードで行う。MySQL 接続は設定ファイルの `mysql_verification` が制御する（既定 `enabled: false`）。パスワードの取得方法は `auth_method` で選ぶ（`parameter_store` / `plaintext` / `prompt`）。**読むパラメータ名は config（サービスごと）が決め、CloudFormation の `MySqlCredentialsParameterPath` は `ssm:GetParameter` を許す階層（例 `/rds-bg/staging`）にすぎない**——パイプラインは環境ごとに 1 本なので、その環境の全サービスのパラメータを同じ階層の下に置く。ARN のリストにしないのは、CloudFormation にリストの各要素へ `!Sub` をかける手段が無く、名前から ARN を組めないためである（階層 1 つなら `!Sub` で組める）。**この階層には移行作業用のパラメータだけを置く**（配下すべてが読めるため）。SecureString がカスタマー管理キーなら `MySqlCredentialsKmsKeyArn` も渡す（`kms:ViaService` で SSM 経由に限定した `kms:Decrypt` が付く。AWS 管理キーなら不要で、復号は SSM 側なので `kms` の VPC endpoint は要らない）。**`parameter_store` ではユーザー名も必ず秘匿側へ置く**——`parameter_name`（パスワード）と `user_parameter_name`（ユーザー名）の両方が必須で、config の `user` は使わない。`plaintext` / `prompt` では config の `user` が必須である。解決は `scripts/collect_green_runtime_values.rb` が担い（設定の読み取り・SSM からの取得・対話入力まで）、値は環境変数で実効値収集バイナリのプロセスにだけ渡す。**`plaintext` は設定ファイルが Git 追跡対象であるためテスト環境専用で、`environment: production` では拒否される。** **カタログからの生成（`generate_blue_green_config`）は `auth_method: parameter_store` 固定で出力する。**`secrets_manager` と `iam`（IAM データベース認証）は対応しない——不正な `auth_method` として拒否される。
- **RDS パラメータグループの変更経路は CloudFormation のみ。** Blue/Green Deployment 自体は CFn カスタムリソースを使わず AWS CLI で扱う。
- 破壊的 RDS 権限（`rds:DeleteDBInstance` 等）は**パイプラインのどの実行ロールも持たない。**Step 7（後始末）はパイプラインから外して人が実行するツール `tools/cleanup.sh` にしたため、実行する作業者がこの権限を持つロールを引き受ける。不可逆な削除を、切り戻し不要の判断・逆方向レプリケーションの確認と一体で人が行うためである。ツールも `actions.cleanup: approved` の宣言が無ければ何もしない。
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
| `scripts/` | CI から到達する実行スクリプトと、その共有ライブラリ（`lib/` / `internal/`）、Step 4 の Go コマンド 2 本。ビルド時の構成検査 `resolve_go_module_root.sh` もここ |
| `tools/` | **人が手で実行するもの一式。**Step 7 の後始末（`cleanup.sh`。設定の読み取りとフェーズ判定は `scripts/lib/` を使い、複製しない）、Step 1・2 の収集・判定（`collect_blue_green_prereqs.sh` / `evaluate_blue_green_prereqs.rb` / 成立条件チェックの MySQL 側の収集 `collect_blue_mysql_state`（`mysql` を exec）・`collect_blue_upgrade_check`（`mysqlsh` を exec。ロジックは `internal/mysqlcli`。判定には未接続）/ `collect_mysql84_parameter_inputs.sh` / `generate_mysql84_parameter_group.rb`）、Blue/Green 設定の Go コマンド（`collect_rds_instance_inventory` / `generate_blue_green_config` / `generate_blue_green_config_report`）と、そのライブラリ（`internal/`）。**使い方の索引は `tools/README.md`**（ツールごとの用途・入出力・主なオプション・終了コードと詳細ドキュメントへのリンク）。Step 1 の取得処理を 1 つずつ実行する手順は `tools/collect_blue_green_prereqs.md` |
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

`scripts/collect_green_runtime_values.rb` は `--config` / `--service` / `--host` を受け取り、`mysql_verification` を読んで**収集するか・接続情報の解決・収集バイナリの起動**までを行う（無効なら何もせず、出力ファイルも作らない）。`verify_green.sh` は呼ぶだけで、MySQL の接続情報を扱わない。パスワードはコマンド引数・標準出力・成果物に出さず、環境変数で収集バイナリへ渡す。`auth_method: prompt` のときは対話入力を促す（エコーしない）。**端末が無い（CI）のに対話入力が要る場合は待たずに止まる。**

**Step 4 の突き合わせは Go のレポート生成器（判定器）にある。**エンジンバージョン・インスタンスクラス・パラメータグループの関連付けと適用状態・レプリカ遅延、そして CloudFormation 宣言値と RDS の実値の比較は、すべてレポート生成器が行う。`verify_green.sh` は AWS から JSON を落として渡すだけで、**判定を持たない**。

フラグで動作を選ぶ。**両方を同時に指定できる。**

| フラグ | 動作 |
|---|---|
| `--check` | 突き合わせを行い、不適合なら**終了コード 1**。理由を stderr へ出す |
| `--output FILE` | Markdown レポートを書き出す |
| 両方 | 検証し、結果をレポートの「0. 検証結果」にも載せる |
| どちらも無し | 使い方の誤りとして終了コード 2 |

設定の宣言値は `--expect-engine-version` / `--expect-instance-class` / `--expect-parameter-group` で渡す（空にした項目は検査しない）。**`--check` を付けないと突き合わせは行わない**——収集済みファイルから読み物を作り直すだけの用途で落とさないためである。

**レポートの内容と終了コードは必ず一致する。**不適合は「レポートに書いて終わり」にせず、終了コードへ反映する。

**Step 4 は同じ Go プログラムで 2 つの実行形態を賄う。**MySQL 実効値の収集は Green DB への到達が必要で、リモート（CodeBuild）では VPC 構成が別途要るため成立しない場合がある。そのときは MySQL 接続を伴う確認をローカルから行い、レポート出力までローカルで完結させる。

| 実行形態 | MySQL 接続 | レポート生成器へ渡す引数 | 「MySQL 実効値」列 |
|---|---|---|---|
| リモート（CodeBuild／GitHub Actions） | しない | `--runtime-values` を渡さない | `未収集` |
| ローカル | する | `--runtime-values <収集結果 JSON>` | 収集した実効値 |

**実効値の有無で変わるのはこの列だけで、判定は AWS API から取得した値で行う。**リモートでも判定内容は変わらない。この性質は `tests/cfn_shorthand_test.sh` が両形態を突き合わせて固定しているので、**レポート生成器を変更したら両形態のテストを通すこと。**

**Step 4 は収集（2 本）と判定（1 本）が別コマンドになっている。**このうち AWS の状態収集だけは **Ruby 版 `scripts/collect_green_state.rb` を `verify_green.sh` が `ruby` で直接呼ぶ。**Go 版も同じ内容で残してあり、**どちらを変えてももう一方へ同じ変更を入れる**（`tests/green_tools_go_rb_parity_test.sh` が終了コード・標準出力・標準エラー・書き出すファイル・AWS CLI の呼び出し引数の一致を検査する）。**判定器（レポート生成器）と実効値収集器は Go である。**どちらも CloudFormation テンプレートの読み取り（`scripts/internal/cfn`）を使うため、Ruby へ移すと同じ読み取りを Ruby でも持つことになり、実装が増えるだけだからである。3 本とも `BuildReportTool` がビルドして artifact で渡す（状態収集の Go 版は、残している間は引き続きビルドする）。

| バイナリ | ソース | 役割 | 受け取る環境変数 |
|---|---|---|---|
| `collect_green_state` | **実行は Ruby**: `scripts/collect_green_state.rb`（ロジックは `scripts/lib/green_state.rb`）。Go 版 `scripts/collect_green_state/`（`scripts/internal/greenstate`）は残置 | **AWS の状態収集**。Deployment を source ARN で引き当て、Green・パラメータ 3 種・レプリカ遅延を JSON 一式で書き出す | `GREEN_STATE_COLLECTOR` |
| `collect_green_runtime_values` | `scripts/collect_green_runtime_values/` | Green DB の実効値収集 | `GREEN_RUNTIME_COLLECTOR` |
| `generate_green_verification_report` | `scripts/generate_green_verification_report/` | 突き合わせ（`--check`）とレポートの組み立て。**AWS を呼ばない** | `GREEN_REPORT_GENERATOR` |

`collect_green_state` の出力ディレクトリは判定器の **`--input-dir`** でそのまま渡せる（ファイル名は `lib/green_state.rb` と Go の `greenstate` の定数で揃えてある。**名前を変えるときは収集器の Go / Ruby と判定器をすべて変える**）。`verify_green.sh` に残るのは、引数と設定の読み取り、**フェーズ判定**（`build_green` / `switchover` / `cleanup` と共有する判定のため Go へ移さない。実装は `lib/migration_phase.rb`）、MySQL 接続情報の解決、3 本の呼び出しだけである。

**VerifyGreen はどれもビルドしない。**`BuildReportTool` が作った 3 本のうち 1 本でも欠けていれば理由を出して停止する（Ruby へ切り替えた状態収集の Go バイナリも、Go 版を残している間は同じく要求する）（Go も外部ネットワークも持たない前提のため、自動復旧しない）。ローカル実行で環境変数を指定しなかった場合だけ、各スクリプトが一時ファイルへビルドして使う。Docker は使わない（`PrivilegedMode` も不要）。

**CodeBuild のイメージは全プロジェクトで `aws/codebuild/standard:7.0` 固定である。**カスタムイメージを指定する経路はテンプレートから削除してある（`VerifyGreenImage` パラメータ・`ImagePullCredentialsType`・ECR 読み取り権限を撤去）。同イメージは jq・rbenv（Ruby 3.4.10）・AWS CLI v2 を持ち、欠けていた mysql クライアントは Go バイナリで置き換えたためである。旧方式の `ci/Dockerfile.verify-green` は**未使用のまま参考として残している**（冒頭にその旨を明記）。

**CloudFormation テンプレートの読み取りは `internal/cfn` が担う。**短縮記法（`!Ref` / `!Sub`）を長形式へ正規化し、値が組み込み関数の項目は「比較不能」として比較対象から外す。レポート生成器・実効値収集器が `scripts/internal/cfn` を、`tools/generate_blue_green_config_report` が `tools/internal/cfn` を使う。**この 2 本は同一内容の複製なので、短縮記法の扱いを変えるときは両方を直す**（`tests/cfn_shorthand_test.sh` が一致を検査する）。

## 実行方法

### 前提

### 実装言語の使い分け

**プログラムは Go、設定 YAML の読み取りは Ruby、AWS 応答などの JSON の取り出しは jq。**理由と適用範囲は `decisions/implementation-language-policy.md`（採択済み）にある。

- **新しいプログラムは Go で書く。**
- **`scripts/` 配下のうち、buildspec から直接呼ばれない 3 本は Ruby へ置き換えた。**`create_blue_green_deployment` / `switchover_blue_green_deployment` / `collect_green_runtime_values` である。**シェル版（`.sh`）は削除した。**呼び出し側は `ruby <パス>` で `.rb` を呼ぶ（実行ビットに頼らない。`tests/ruby_invocation_test.sh` が検査する）。Ruby 版は設定 YAML を psych で直接読むため **jq を必要としない**（`scripts/lib/deployment_config.rb`）。AWS は SDK ではなく **AWS CLI を exec する**ので、権限・プロファイル・リージョンの解決はシェルから呼ぶ場合と完全に同じである（`scripts/lib/aws_cli.rb`）
- **buildspec から直接呼ばれる 6 本と `resolve_go_module_root.sh` はシェルのまま。**`scripts/lib/*.sh` は `source` されて呼び出し元のシェル変数を作るため、それ自体を Ruby へ置き換えることはできない。ただし**判定ロジックは Ruby へ出せる**——シェルは `ruby <実装>.rb <サブコマンド> ...` を直接呼んで結果を受け取る（`migration_phase.rb` がこの形。呼び出し側は `migration_phase=(ruby "$(dirname "$0")/lib/migration_phase.rb")` と配列に入れて `"${migration_phase[@]}" resolve ...` で使う）。**同じ名前のシェル関数で包む委譲ラッパーは作らない**——回りくどく、実装の場所も分かりにくくなるため
- 既存の Ruby（`evaluate_blue_green_prereqs.rb`、`generate_mysql84_parameter_group.rb`）は**一律には移行しない。**テスト可能性が問題になったものから順に移す。`.rb` を全廃しても、設定 YAML の読み取りが Ruby ランタイムを要求し続けるため依存は消えない
- `examples/mysql-timezone-replication/probe/` の Go / Ruby / Python は**移行対象外**である。ドライバごとの `time_zone` の扱いの違いを示すことが目的で、3 実装が並ぶこと自体が結論の根拠になっている

**設定 YAML の読み取りは `scripts/lib/deployment_config.rb` の 1 か所だけが行う。**Ruby からは `require_relative` して使い、シェルからはコマンドとして呼んで `NAME='値'` の代入行を受け取る。psych（Ruby 標準ライブラリ）で直接読むので、**設定の読み取りに jq は使わない**し、追加パッケージの導入も要らない。

- 設定 YAML → 取り出す項目を **`変数名=種別:パス[=既定値]`** で宣言して呼ぶ。種別は `required`（空・未定義なら `<パス> が未定義である` で終了コード 1）/ `optional`（既定値へ倒す）/ `flag`（`"true"` / `"false"`）。パスは `service.<キー>` がサービス配下、それ以外がトップレベルで、ドットで入れ子を辿る（例: `build=optional:service.actions.build=pending`）。**同じ名前のシェル関数では包まない**（上の方針と同じ）
  ```bash
  config_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
    build=optional:service.actions.build=pending \
    source_id=required:service.source_db_instance_identifier \
    config_region=required:aws_region)
  eval "$config_vars"
  ```
- `mysql_verification` は検証を伴うので専用のサブコマンド `mysql-verification <config> <service>` が `MYSQL_VERIFY_*` を出す（auth_method の検証・production での plaintext 拒否もここ）。パスワード等の解決（SSM 呼び出し）は `scripts/collect_green_runtime_values.rb` が行う
- 値から導く既定値（例: `cleanup.sh` の `final_snapshot_id` の `<source_id>-final`）は宣言に含めず、読み取り後にシェルで補う
- **`eval "$(...)" と 1 行で書かない。**その形はコマンド置換の失敗を `eval` の終了コードが覆い隠すため、**読み取りが失敗しても `set -e` をすり抜けて「変数が空のまま先へ進む」。**いったん変数へ受けてから `eval` する。同じ理由で、buildspec 内で外部コマンドの出力を `eval` するときも 2 行に分ける（`tests/deployment_config_test.sh` が 2 行の形で停止することを検査している）
- AWS 応答などの JSON → jq で直接読む
- **スクリプトに Python を書かない。**YAML を扱うのは Ruby、JSON は jq である
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

# MySQL 接続方式の検証と、解決から収集までの流れのテスト（AWS へも DB へも接続しない）
tests/mysql_credentials_test.sh

# Step 3 の分岐（承認・フェーズ判定・Deployment の状態・保護スナップショット）のテスト
tests/build_green_test.sh

# 呼び出し側のシェルが .rb を ruby 経由で呼んでいるか（実行ビットに頼らない）のテスト
tests/ruby_invocation_test.sh

# CloudFormation 短縮記法（!Ref / !Sub）を 3 実装が同じに解釈するかのテスト
tests/cfn_shorthand_test.sh

# Step 4 の状態収集の Go 版と Ruby 版が同じに振る舞うかのテスト（AWS へ接続しない）
tests/green_tools_go_rb_parity_test.sh

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
