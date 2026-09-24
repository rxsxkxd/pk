# Blue/Green 成立条件チェック

| 項目 | 値 |
|---|---|
| 対象インスタンス | `example-service-production-mysql80` |
| エンジン | mysql 8.0.39 |
| インスタンスクラス | db.r6g.large |
| 判定対象バージョン | 8.4 |
| 収集日時 | 2026-09-17T00:00:00Z |
| 判定 | **移行可能**（STOP なし） |

**PASS 12 件 / REVIEW 2 件 / STOP 0 件**

## 判断材料と値

判定の根拠になった観測値と、その値を読んだ収集ファイルを示す。

| 判定 | 項目 | 観測値 | 取得元 |
|---|---|---|---|
| PASS | 0-1-01 自動バックアップ | BackupRetentionPeriod=7 | `db-instance.json` |
| REVIEW | 0-1-02 binlog_format | MIXED（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断） | `db-parameters.json` |
| PASS | 0-1-05 パラメータ適用状態 | in-sync | `db-instance.json` |
| PASS | 0-1-03 オプショングループ | default:mysql-8-0 | `db-instance.json` |
| PASS | 0-1-04 MEMCACHED | 設定なし | `option-group.json` |
| REVIEW | 0-1-06 外部 binlog レプリカ | AWS CLI のみでは判定不可。SHOW REPLICA STATUS\G の結果が空であることを手動確認 | `手動確認（収集対象外）` |
| PASS | 0-1-07 カスケードリードレプリカ | 直接配下=1 | `all-db-instances.json` |
| PASS | 0-1-08 インスタンスクラス | db.r6g.large / target=8.4 | `orderable-classes.json` |
| PASS | 0-1-09 空きストレージ | 直近1時間の最小値: 60.00 GiB | `free-storage-space.json` |
| PASS | 0-1-10 Secrets Manager 管理パスワード | 利用なし | `db-instance.json` |
| PASS | 0-1-11 Zero-ETL 統合 | 関連統合なし | `integrations.json` |
| PASS | 0-1-12 クロスリージョンリードレプリカ | 検出なし | `db-instance.json` |
| PASS | 0-1-13 RDS Proxy | このリージョンに Proxy なし | `db-proxies.json / db-proxy-targets-*.json` |
| PASS | 0-1-14 IAM DB 認証 | 無効 | `db-instance.json` |

## REVIEW — 人の確認が要る

- **0-1-02 binlog_format** … MIXED（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断）（`db-parameters.json`）
- **0-1-06 外部 binlog レプリカ** … AWS CLI のみでは判定不可。SHOW REPLICA STATUS\G の結果が空であることを手動確認（`手動確認（収集対象外）`）

## この結果の読み方

- **STOP が 1 件でも残る間は移行できない。**先に解消する
- **REVIEW は自動判定では決められない項目である。**人が確認して可否を決める
- このレポートは収集済み JSON だけから作る。**AWS へは接続していない**ため、
  収集時点（上記の収集日時）の状態を示す。時間が空いたら再収集する
- 項目の採番は `docs/phase-0-precheck.md` のチェックリストに対応する

この結果をもとに、**移行できるか・どのインスタンスを対象にするか**を判断する。
対象を決めたら次は移行設定の生成とそのレビューへ進む（`report-generation-flows.md`）。
