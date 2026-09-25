# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの性格

AWS RDS for MySQL 8.0 → 8.4 を Blue/Green Deployments で移行するための、**手順書（Markdown）と実行スクリプトと CI 定義が一体になったリポジトリ**である。ドキュメントは日本語で書かれており、追記・修正も日本語で行う。期限は MySQL 8.0 の標準サポート終了（2026-07-31）で、全体の親ドキュメントは `docs/rds-mysql-84-migration-guide.md`。

## 全体アーキテクチャ

1. 移行は 7 ステップ（`docs/upgrade-flow-steps.md`。**レビュー中につき内容と Step 番号は変えない**）で、Step 1・2・7 は人がローカルで `tools/` を実行し、Step 3〜5 は CodePipeline（CodeBuild）が `scripts/` を実行する。
2. 実運用の手順は 2 本だけ——環境構築 `operations-environment-setup.md` と移行の実行 `operations-migration-run.md`。手順を書き足すときはまずどちらに属するかを考え、背景は補足ドキュメントへ置いてリンクする。
3. 判断は 3 回のゲート（①成立条件チェック ②設定レビュー ③切替前検証）で、それぞれのレポートの生成元は `report-generation-flows.md`。チェックの呼び分け（成立条件チェック／構築前チェック／切替前検証）は `operations-migration-run.md`。
4. 入力は環境ごとの `config/blue-green/<env>.deployment.yml` 1 本で、全エントリポイントが `--config FILE --service NAME` を取る。生成方法は `docs/config-blue-green-generation-design.md`。
5. パイプラインの構成・パラメータ・権限は `ci/README.md`・`ci/codepipeline-structure.md`・`ci/codepipeline-all-in-one-parameters.md`、ツールの使い方の索引は `tools/README.md` にある。

## 実装のルール（逸脱する変更を入れない）

**言語と役割の分担**

| 場所 | 役割 | 言語 |
|---|---|---|
| `tools/` | 人が手で実行するもの（Step 1・2・7、設定生成） | **Go のみ**（ロジックは `tools/internal/`、`main` は配線だけ） |
| `scripts/*.sh` | buildspec から呼ばれるエントリポイント | **シェル。できる限り簡素に**——引数・設定の読み取り・Ruby / Go の呼び出し・終了コードだけ |
| `scripts/*.rb`・`scripts/lib/*.rb` | パイプラインの **AWS 操作**と設定 YAML の読み取り | **Ruby**（AWS は `scripts/lib/aws_cli.rb` 経由で AWS CLI を exec。SDK は使わない） |
| `scripts/<名前>/`（Go） | パイプラインの **MySQL クエリ**と判定・レポート | **Go**（BuildReportTool がビルドし artifact で渡す） |

- **シェルから `aws` / `mysql` を直接実行しない。**AWS 操作は Ruby、MySQL クエリは Go に置き、シェルはそれを呼ぶだけにする。フェーズ判定の観測も `ruby scripts/lib/migration_phase.rb observe` が行う。シェルが Ruby を呼ぶだけになるなら、シェルを作らず buildspec から `ruby scripts/<名前>.rb` を直接呼ぶ（例: `check_target_parameter_group.rb`）。
- `.rb` は `ruby <パス>` で呼ぶ（CodePipeline の artifact で実行ビットが落ちるため。`tests/ruby_invocation_test.sh`）。同じ名前のシェル関数で包まない。
- 外部コマンドの出力を `eval` するときは**変数へ受けてから 2 行で**。`eval "$(...)"` は失敗が `set -e` をすり抜ける。
- `scripts/` と `tools/` はコードを共有しない。同じ規則を両側で持つもの（フェーズ判定・設定の読み取り・`cfn`）は、変えるときに両側を直す。
- スクリプトに Python を書かない。背景は `docs/decisions/implementation-language-policy.md`。

**設計上の中核ルール**（背景は `docs/decisions/idempotency-strategy.md`）

- **収集と判定を分離する。**収集は AWS の読み取り API だけで JSON を落とし、判定は AWS を呼ばない。変更操作の行には `[変更]` のコメントを付ける。判定系は不適合で終了コード `1`。
- **宣言と実状態の突き合わせ。**設定の `actions`（`pending` / `approved`）は人の宣言で、毎回 AWS の実状態を読んで未適用なら適用する。**設定ファイルへ書き戻さない。**
- **識別子は AWS から引き当てる**（Deployment ID を持たず、移行元 ARN で毎回解決する）。
- **冪等性は二層**——①移行元のエンジンバージョンとパラメータグループで結果を観測（`scripts/lib/migration_phase.rb` / `tools/internal/phase`）、②Deployment の Status。終了コードは「望ましい終了状態に到達しているか」で決める。
- **本番 DB の認証情報を CI に常設しない。**MySQL 接続は設定の `mysql_verification`（既定無効）が制御し、パスワードは SSM Parameter Store から取って環境変数でだけ渡す。`plaintext` は production で拒否。詳細は `ci/codebuild-codepipeline-setup.md`。
- **MySQL の TLS 既定は VERIFY_CA。**`tools/` の接続は `--ssl-mode` で DISABLED / PREFERRED / REQUIRED / VERIFY_CA / VERIFY_IDENTITY を選べる（検証しないモードは警告。`tools/README.md`）。
- **RDS パラメータグループの変更は CloudFormation のみ。**変換ルールの正本は `config/mysql80-to-84-parameter-rules.yml`（コードではなくこれを直す）。
- **破壊的 RDS 権限はパイプラインのどのロールも持たない。**Step 7 は人が `tools/cleanup` で行い、`actions.cleanup: approved` が無ければ何もしない。

**CI**——主系は **CodePipeline + CodeBuild**（`ci/codebuild/*.yml`、`examples/rds-blue-green-deployment/codepipeline-all-in-one.yml`）。イメージは全プロジェクト `aws/codebuild/standard:7.0` 固定。`.github/workflows/` にも同じ `scripts/*.sh` を呼ぶ定義があるので、スクリプトの引数を変えたら併せて確認する。

## コマンド

```bash
# Step 1・2（ローカル。詳細とオプションは tools/README.md）
go run ./tools/collect_blue_green_prereqs --db-instance-id <blue-id> --region <region> --output-dir <dir>
go run ./tools/evaluate_blue_green_prereqs --input-dir <dir> --output <dir>/prereqs-evaluation-report.md
go run ./tools/collect_mysql84_parameter_inputs --source-parameter-group <8.0-pg> --output-dir <dir>
go run ./tools/generate_mysql84_parameter_group --input-dir <dir> --output-dir <out> --system <name> --environment <env>

# Step 3〜5（CodeBuild と同じエントリポイント。pending なら何もせず正常終了）
scripts/build_green.sh  --config config/blue-green/staging.deployment.yml --service example-service
scripts/verify_green.sh --config config/blue-green/staging.deployment.yml --service example-service
scripts/switchover.sh   --config config/blue-green/staging.deployment.yml --service example-service --approve

# Step 7（ローカル。破壊的権限を持つロールで実行）
go run ./tools/cleanup --config config/blue-green/staging.deployment.yml --service example-service
```

コンテナでの実行（`compose.yaml`）は `docs/local-execution.md`、buildspec のローカル実行は `ci/codebuild-local-verification.md`。

## 変更の検証

```bash
go vet ./... && go build ./... && go test ./...          # Go 全体（ゴールデンファイルとの一致を含む）
bash -n scripts/*.sh tests/*.sh                           # シェルの構文
for t in tests/*_test.sh; do "$t" >/dev/null || echo "FAIL $t"; done   # シェル側のテスト一式
tests/test_generate_blue_green_config.sh                  # 設定生成のテスト
grep -nP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' scripts/*.sh tests/*.sh   # `$VAR）` は set -u で落ちる。`${VAR}）` と書く
```

`examples/mysql84-parameter-generation/` と `examples/blue-green-prereqs/` の出力はゴールデンファイルである。ルールや生成器を変えたら `go run` で再生成し、差分をレビューする。

## 編集時の注意

- `.env`、`ci/.act.env`、`aws-config/*`、`global-bundle.pem` は `.gitignore` 済み。`my.cnf` は空プレースホルダとして追跡しており、実接続情報を書き込んで commit しない。
- ドキュメント間の相互参照が密である。Step の分割や実行形態を変えたら `docs/upgrade-flow-steps.md`（パスのみ）・`ci/README.md`・`tools/README.md`・`examples/*/README.md`・該当 `docs/phase-*.md` を揃えて更新する。
- コンテナイメージは `latest` を使わない。AWS CLI・MySQL・Ruby はパッチまで、Go はマイナーまで固定し、Ruby は `ruby:3.4.10-slim-bookworm` に統一する。
