# RDS for MySQL 8.0 → 8.4 アップグレード

AWS RDS for MySQL 8.0 → 8.4 を Blue/Green Deployments で移行するための、手順書・実行スクリプト・CI 定義一式。期限は MySQL 8.0 の標準サポート終了(2026-07-31、8/1 以降は Extended Support が自動課金)。

## まず読むもの

作業の背骨は次の1本。他のドキュメントはすべてこれの詳細リファレンスか、周辺の技術メモ・記録である。

- **[upgrade-flow-steps.md](upgrade-flow-steps.md)** — Step 1〜7 の分割、実装状況、実行形態(ローカル/CI)、設定ファイルによるアクション管理。**現在レビュー中のため内容・番号体系は変更しない。**

Step の詳細を掘り下げる際に参照する:

- [rds-mysql-84-migration-guide.md](rds-mysql-84-migration-guide.md) — Phase 0〜5 の詳細手順書(移行元の親ドキュメント)
- [phase-0-precheck.md](phase-0-precheck.md) — Step 1 の詳細。Blue/Green 成立条件チェックリスト(0-1-01〜14)
- [phase-1-parameter-group-cloudformation.md](phase-1-parameter-group-cloudformation.md) — Step 2 の詳細。CloudFormation による DB パラメータグループ管理
- [config-blue-green-generation-design.md](config-blue-green-generation-design.md) — RDS インベントリと人が管理する対応表から Blue/Green 設定 YAML を生成する支援ツールの最小設計
- [migration-catalog-er.md](migration-catalog-er.md) — 移行カタログ(アプリケーション、接続、環境、パラメータグループ)の ER 図。YAML 構造の正本
- [direct-blue-green-execution.md](direct-blue-green-execution.md) — `scripts/*.sh` を直接実行する場合の、パラメータグループ事前確認から後始末までの一連手順
- [ci/verify-green-vpc-architecture.md](ci/verify-green-vpc-architecture.md) — Step 4 を「Go のビルド」と「検証の実行」に分け、実行側だけを RDS のある VPC 内へ置く構成（図つき）
- [ci/verify-green-security-group-setup.md](ci/verify-green-security-group-setup.md) — 上記構成で必要なセキュリティグループの設定手順（テンプレートは SG を作らない）

エージェント向けの作業ガイドは [CLAUDE.md](CLAUDE.md)。

## Step 3〜5 の実行方式

BuildGreen（Step 3）、VerifyGreen（Step 4）、Switchover（Step 5）は、実行目的に応じて次の三つの方式を使い分ける。実行方式が違っても、各 Step が呼び出すシェルスクリプトと設定 YAML は共通である。

| 実行方式 | 主な用途 | 実行対象 | 起動元 |
|---|---|---|---|
| スクリプト直接ローカル実行 | 個別スクリプトの切り分け・日常確認 | `scripts/{build_green,verify_green,switchover}.sh` | シェルスクリプトを直接起動 |
| CodeBuild Local Agent | buildspec・環境変数・artifact・Docker を含む CodeBuild 互換性確認 | `ci/codebuild/{build-green,verify-green,switchover}.yml` | Local Agent 経由で buildspec を起動 |
| AWS CodeBuild / GitHub Actions | CI 上の継続的な検証 | CodeBuild buildspec / GitHub Actions workflow | リモート CI から起動 |

VerifyGreen のレポート生成器だけは、直接実行時に `GREEN_REPORT_GENERATOR` を指定しなければ Ruby を使う。一方、CodeBuild Local Agent、AWS CodeBuild、GitHub Actions は Docker Buildx で Go バイナリを作成して指定する。この違いはレポート生成器の実装・実行環境上の補足であり、検証対象・判定内容を変えるものではない。

直接実行の一連手順は [direct-blue-green-execution.md](direct-blue-green-execution.md)、CodeBuild Local Agent の手順は [ci/codebuild-local-verification.md](ci/codebuild-local-verification.md) を参照する。

## フォルダ構成

| フォルダ | 内容 |
|---|---|
| `scripts/` | **CI（CodeBuild / GitHub Actions）から到達する**実行スクリプト。Step 3〜5 と Step 4 のレポート生成器 |
| `tools/` | **人が手で実行する**コマンド。Step 1・2 の収集と判定、Blue/Green 設定の生成。[tools/README.md](tools/README.md) |
| `tests/` | テスト一式(`bash tests/*.sh` と `go test ./...`) |
| `config/` | 環境別設定ファイル(`blue-green/{staging,production}.yml`)とパラメータ変換ルール |
| `ci/` | GitHub Actions / CodeBuild・CodePipeline の実行定義。[ci/README.md](ci/README.md) |
| (ルート直下) | ローカル実行用コンテナ定義。`compose.yaml`、`aws-config/`、`global-bundle.pem`、`my.cnf`。[local-execution.md](local-execution.md) |
| `examples/` | サンプル入出力・CLI 実行例・ローカル検証環境 |
| `reference/` | 判断に使う技術リファレンス(手順書ではない) |
| `decisions/` | 結論→理由→代替案評価の意思決定記録(ADR)。未採択の検討中メモも含む |
| `reports/` | 完了した作業の実施記録 |

### `reference/`

- [innodb-mysql80-to-84-parameter-mapping.md](reference/innodb-mysql80-to-84-parameter-mapping.md) — InnoDB 関連パラメータの 8.0→8.4 マッピング
- [mysql-slow-query-log.md](reference/mysql-slow-query-log.md) — スロークエリログ関連パラメータの整理
- [mysql-timezone-problem-summary.md](reference/mysql-timezone-problem-summary.md) — **判断材料の要約**。`time_zone` を `Asia/Tokyo` へ変更すると `DEFAULT CURRENT_TIMESTAMP` の `datetime` 列で何が起きるか
- [mysql-timezone.md](reference/mysql-timezone.md) — タイムゾーン関連パラメータ(`time_zone`、`system_time_zone`、`explicit_defaults_for_timestamp`)の整理
- [mysql-timezone-replication-verification.md](reference/mysql-timezone-replication-verification.md) — ソースとレプリカで `time_zone` が異なる場合の挙動を AWS 上で実証する検証手順(使い捨て構成の作成・検証・後始末)。AWS を使わない場合は [examples/mysql-timezone-replication/](examples/mysql-timezone-replication/) のローカル擬似環境を使う
- [shared-instance-upgrade-verification.md](reference/shared-instance-upgrade-verification.md) — **ステージと本番が同一インスタンスに同居している場合**の移行手順。使い捨て検証機の構築・検証・後始末と、同居構成での既存スクリプトの誤動作
- [step-script-language-matrix.md](reference/step-script-language-matrix.md) — Step 別のスクリプト対応表と、実行に必要な言語環境(Bash/Python/Ruby/Go/MySQL クライアント)の一覧
- [source-article-notes.md](reference/source-article-notes.md) — 出典記事の要約メモ(参考。正典ではない)

### `decisions/`

- [cdk-adoption-considerations.md](decisions/cdk-adoption-considerations.md) — CDK 導入の判断資料(結論: 現状は CloudFormation のみで運用)
- [binlog-format-bluegreen-compatibility.md](decisions/binlog-format-bluegreen-compatibility.md) — Blue `MIXED` → Green `ROW` の Blue/Green レプリケーション互換性
- [structure-review-proposal.md](decisions/structure-review-proposal.md) — リポジトリ構成・フロー全体の見直し対案(**未採択**。着手順を含む)
- [idempotency-strategy.md](decisions/idempotency-strategy.md) — 各フェーズの冪等性の現状評価とあるべき姿(**未採択**)。switchover が 2 回目に必ず失敗する点、cleanup が部分完了で成功を返す点など
- [implementation-language-policy.md](decisions/implementation-language-policy.md) — 実装言語の役割分担(**採択済み**)。プログラムは Go、シェルからの YAML 読み取りは Ruby、JSON は jq。Step 4 をローカル実行前提に寄せる判断を含む

### `reports/`

- [inline-python-reduction-report.md](reports/inline-python-reduction-report.md) — `scripts/*.sh` のインライン `python3 -c` 削減対応記録(38→8箇所)

## 現在の既知の未決事項

- `structure-review-proposal.md` の論点1〜8(実装言語の統一、判定ロジックのテスト、切り戻し Step 化、ワンショット/二段階昇格の選択など)は未着手。
- `runbook`(このREADMEの「まず読むもの」節)は物理的なフォルダ移動を見送っている。レビュー完了後に再検討する。
