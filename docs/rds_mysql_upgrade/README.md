# RDS for MySQL 8.0 → 8.4 アップグレード

AWS RDS for MySQL 8.0 → 8.4 を Blue/Green Deployments で移行するための、手順書・実行スクリプト・CI 定義一式。期限は MySQL 8.0 の標準サポート終了(2026-07-31、8/1 以降は Extended Support が自動課金)。

## まず読むもの

作業の背骨は次の1本。他のドキュメントはすべてこれの詳細リファレンスか、周辺の技術メモ・記録である。

- **[upgrade-flow-steps.md](upgrade-flow-steps.md)** — Step 1〜7 の分割、実装状況、実行形態(ローカル/CI)、設定ファイルによるアクション管理。**現在レビュー中のため内容・番号体系は変更しない。**

Step の詳細を掘り下げる際に参照する:

- [rds-mysql-84-migration-guide.md](rds-mysql-84-migration-guide.md) — Phase 0〜5 の詳細手順書(移行元の親ドキュメント)
- [phase-0-precheck.md](phase-0-precheck.md) — Step 1 の詳細。Blue/Green 成立条件チェックリスト(0-1-01〜14)
- [phase-1-parameter-group-cloudformation.md](phase-1-parameter-group-cloudformation.md) — Step 2 の詳細。CloudFormation による DB パラメータグループ管理

エージェント向けの作業ガイドは [CLAUDE.md](CLAUDE.md)。

## フォルダ構成

| フォルダ | 内容 |
|---|---|
| `scripts/` | 各 Step の収集・判定・実行スクリプト。[scripts/README.md](scripts/README.md) |
| `config/` | 環境別設定ファイル(`blue-green/{staging,production}.yml`)とパラメータ変換ルール |
| `ci/` | GitHub Actions / CodeBuild・CodePipeline の実行定義。[ci/README.md](ci/README.md) |
| `docker/` | ローカル実行用コンテナ定義。[docker/README.md](docker/README.md) |
| `examples/` | サンプル入出力・CLI 実行例 |
| `reference/` | 判断に使う技術リファレンス(手順書ではない) |
| `decisions/` | 結論→理由→代替案評価の意思決定記録(ADR)。未採択の検討中メモも含む |
| `reports/` | 完了した作業の実施記録 |

### `reference/`

- [innodb-mysql80-to-84-parameter-mapping.md](reference/innodb-mysql80-to-84-parameter-mapping.md) — InnoDB 関連パラメータの 8.0→8.4 マッピング
- [mysql-slow-query-log.md](reference/mysql-slow-query-log.md) — スロークエリログ関連パラメータの整理
- [source-article-notes.md](reference/source-article-notes.md) — 出典記事の要約メモ(参考。正典ではない)

### `decisions/`

- [cdk-adoption-considerations.md](decisions/cdk-adoption-considerations.md) — CDK 導入の判断資料(結論: 現状は CloudFormation のみで運用)
- [binlog-format-bluegreen-compatibility.md](decisions/binlog-format-bluegreen-compatibility.md) — Blue `MIXED` → Green `ROW` の Blue/Green レプリケーション互換性
- [structure-review-proposal.md](decisions/structure-review-proposal.md) — リポジトリ構成・フロー全体の見直し対案(**未採択**。着手順を含む)

### `reports/`

- [inline-python-reduction-report.md](reports/inline-python-reduction-report.md) — `scripts/*.sh` のインライン `python3 -c` 削減対応記録(38→8箇所)

## 現在の既知の未決事項

- `structure-review-proposal.md` の論点1〜8(実装言語の統一、判定ロジックのテスト、切り戻し Step 化、ワンショット/二段階昇格の選択など)は未着手。
- `runbook`(このREADMEの「まず読むもの」節)は物理的なフォルダ移動を見送っている。レビュー完了後に再検討する。
