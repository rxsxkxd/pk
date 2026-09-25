# Blue/Green 成立条件チェック

| 項目 | 値 |
|---|---|
| 対象インスタンス | `example-service-production-mysql80` |
| エンジン | mysql 8.0.39 |
| インスタンスクラス | db.r6g.large |
| 判定対象バージョン | 8.4 |
| 収集日時 | 2026-09-17T00:00:00Z |
| 判定 | **移行可能**（STOP なし） |

**PASS 14 件 / REVIEW 2 件 / STOP 0 件**

## 判断材料と値

判定の根拠になった観測値と、その値を読んだ収集ファイルを示す。

| 判定 | 項目 | 観測値 | 取得元 |
|---|---|---|---|
| PASS | 0-1-01 自動バックアップ | BackupRetentionPeriod=7 | `db-instance.json` |
| REVIEW | 0-1-02 binlog_format | MIXED（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断）。実効値=MIXED | `db-parameters.json` |
| PASS | 0-1-05 パラメータ適用状態 | in-sync | `db-instance.json` |
| PASS | 0-1-03 オプショングループ | default:mysql-8-0 | `db-instance.json` |
| PASS | 0-1-04 MEMCACHED | 設定なし | `option-group.json` |
| PASS | 0-1-06 外部 binlog レプリカ | SHOW REPLICA STATUS が空（外部からのレプリカではない） | `blue-mysql-state.json` |
| PASS | 0-1-07 カスケードリードレプリカ | 直接配下=1 | `all-db-instances.json` |
| PASS | 0-1-08 インスタンスクラス | db.r6g.large / target=8.4 | `orderable-classes.json` |
| PASS | 0-1-09 空きストレージ | 直近1時間の最小値: 60.00 GiB | `free-storage-space.json` |
| PASS | 0-1-10 Secrets Manager 管理パスワード | 利用なし | `db-instance.json` |
| PASS | 0-1-11 Zero-ETL 統合 | 関連統合なし | `integrations.json` |
| PASS | 0-1-12 クロスリージョンリードレプリカ | 検出なし | `db-instance.json` |
| PASS | 0-1-13 RDS Proxy | このリージョンに Proxy なし | `db-proxies.json / db-proxy-targets-*.json` |
| PASS | 0-1-14 IAM DB 認証 | 無効 | `db-instance.json` |
| PASS | 0-2 InnoDB 以外のテーブル | ユーザースキーマに InnoDB 以外のテーブルなし | `blue-mysql-state.json` |
| REVIEW | 0-3 アップグレードチェッカー | Error=0 / Warning=20 / Notice=2（target=8.4.9）。Warning は個別に判断する | `blue-upgrade-check.json` |

## MySQL 側の収集結果

Blue へ接続して集めた、AWS API では見えない情報である。0-1-06・0-2・0-3 の判定と、0-1-02 の実効値の確認に使った。

### 接続先の状態（`blue-mysql-state.json`）

| 項目 | 値 |
|---|---|
| 収集日時 | 2026-09-17T00:05:00Z |
| 接続先 | `example-service-production-mysql80.xxxxxxxxxxxx.ap-northeast-1.rds.amazonaws.com:3306` |
| MySQL バージョン | 8.0.39 |
| binlog_format（実効値） | MIXED |
| SHOW REPLICA STATUS | 0 行 |
| InnoDB 以外のテーブル | 0 件 |

**SHOW REPLICA STATUS**（0-1-06。空なら Blue は外部からのレプリカではない）

空（レプリケーションの受け側になっていない）。

**InnoDB 以外のテーブル**（0-2。ユーザースキーマのみ。MyISAM は binlog レプリケーションで整合性が保証されない）

なし。

### MySQL Shell アップグレードチェッカー（`blue-upgrade-check.json`）

| 項目 | 値 |
|---|---|
| 収集日時 | 2026-09-17T00:10:00Z |
| 接続先 | `example-service-production-mysql80-upgrade-check.xxxxxxxxxxxx.ap-northeast-1.rds.amazonaws.com:3306` |
| サーバー | 8.0.39 - Source distribution |
| 移行先バージョン | 8.4.9 |
| Error / Warning / Notice | 0 / 20 / 2 |
| mysqlsh の終了コード | 0 |
| 要約 | No fatal errors were found that would prevent an upgrade, but some potential issues were detected. Please ensure that the reported issues are not significant before upgrading. |

**検査項目**

| 検査 | 状態 | 検出件数 |
|---|---|---|
| Removed system variables（`removedSysVars`） | OK | 0 |
| System variables with new default values（`sysVarsNewDefaults`） | OK | 20 |
| Issues reported by 'check table x for upgrade' command（`checkTableCommand`） | OK | 0 |
| Checks for foreign keys not referencing a full unique index（`foreignKeyReferences`） | OK | 0 |
| Check for deprecated or invalid user authentication methods.（`authMethodUsage`） | OK | 0 |
| Check for deprecated or removed plugin usage.（`pluginUsage`） | OK | 0 |
| Check for deprecated or invalid default authentication methods in system variables.（`deprecatedDefaultAuth`） | OK | 0 |
| Check for deprecated or invalid authentication methods in use by MySQL Router internal accounts.（`deprecatedRouterAuthMethod`） | OK | 0 |
| Checks for errors in column definitions（`columnDefinition`） | OK | 0 |
| Check for allowed values in System Variables.（`sysvarAllowedValues`） | OK | 0 |
| Checks for user privileges that will be removed（`invalidPrivileges`） | OK | 2 |
| Checks for partitions by key using columns with prefix key indexes（`partitionsWithPrefixKeys`） | OK | 0 |

**検出された問題**（Error を先に並べる）

| レベル | 検査 | 対象 | 内容 |
|---|---|---|---|
| Warning | `sysVarsNewDefaults` | binlog_transaction_dependency_tracking | default value will change from COMMIT_ORDER to WRITESET. |
| Warning | `sysVarsNewDefaults` | group_replication_consistency | default value will change from EVENTUAL to BEFORE_ON_PRIMARY_FAILOVER. |
| Warning | `sysVarsNewDefaults` | group_replication_exit_state_action | default value will change from READ_ONLY to OFFLINE_MODE. |
| Warning | `sysVarsNewDefaults` | innodb_adaptive_hash_index | default value will change from ON to OFF. |
| Warning | `sysVarsNewDefaults` | innodb_buffer_pool_in_core_file | default value will change from ON to OFF. |
| Warning | `sysVarsNewDefaults` | innodb_buffer_pool_instances | default value will change from 8 (or 1 if innodb_buffer_pool_size < 1GB) to MAX(1, #vcpu/4). |
| Warning | `sysVarsNewDefaults` | innodb_change_buffering | default value will change from all to none. |
| Warning | `sysVarsNewDefaults` | innodb_doublewrite_files | default value will change from innodb_buffer_pool_instances * 2 to 2. |
| Warning | `sysVarsNewDefaults` | innodb_doublewrite_pages | default value will change from innodb_write_io_threads to 128. |
| Warning | `sysVarsNewDefaults` | innodb_flush_method | default value will change from fsynch (unix) or unbuffered (windows) to O_DIRECT. |
| Warning | `sysVarsNewDefaults` | innodb_io_capacity | default value will change from 200 to 10000. |
| Warning | `sysVarsNewDefaults` | innodb_io_capacity_max | default value will change from 200 to 2 x innodb_io_capacity. |
| Warning | `sysVarsNewDefaults` | innodb_log_buffer_size | default value will change from 16777216 (16MB) to 67108864 (64MB). |
| Warning | `sysVarsNewDefaults` | innodb_log_writer_threads | default value will change from ON to OFF ( if #vcpu <= 32 ). |
| Warning | `sysVarsNewDefaults` | innodb_numa_interleave | default value will change from OFF to ON. |
| Warning | `sysVarsNewDefaults` | innodb_page_cleaners | default value will change from 4 to innodb_buffer_pool_instances. |
| Warning | `sysVarsNewDefaults` | innodb_parallel_read_threads | default value will change from 4 to MAX(#vcpu/8, 4). |
| Warning | `sysVarsNewDefaults` | innodb_purge_threads | default value will change from 4 to 1 ( if #vcpu <= 16 ). |
| Warning | `sysVarsNewDefaults` | innodb_read_io_threads | default value will change from 4 to MAX(#vcpu/2, 4). |
| Warning | `sysVarsNewDefaults` | innodb_redo_log_capacity | default value will change from 104857600 (100MB) to MIN ( #vcpu/2, 16 )GB. |
| Notice | `invalidPrivileges` | 'root'@'%' | The user 'root'@'%' has the following privileges that will be removed as part of the upgrade process: SET_USER_ID |
| Notice | `invalidPrivileges` | 'root'@'localhost' | The user 'root'@'localhost' has the following privileges that will be removed as part of the upgrade process: SET_USER_ID |

**検出された検査の説明と対処**（チェッカーが返した内容）

- **System variables with new default values**（`sysVarsNewDefaults`）
  - 説明: Warning: Following system variables that are not defined in your configuration file will have new default values. Please review if you rely on their current values and if so define them before performing upgrade.
  - 資料: https://dev.mysql.com/blog-archive/new-defaults-in-mysql-8-0/
- **Checks for user privileges that will be removed**（`invalidPrivileges`）
  - 説明: Verifies for users containing grants to be removed as part of the upgrade process.
  - 対処: If the privileges are not being used, no action is required, otherwise, ensure they stop being used before the upgrade as they will be lost.

**手動確認が要る項目**（チェッカーが自動では判定しないもの）

なし。

## REVIEW — 人の確認が要る

- **0-1-02 binlog_format** … MIXED（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断）。実効値=MIXED（`db-parameters.json`）
- **0-3 アップグレードチェッカー** … Error=0 / Warning=20 / Notice=2（target=8.4.9）。Warning は個別に判断する（`blue-upgrade-check.json`）

## 補足事項

### 収集の網羅状況

| 収集 | コマンド | 状態 | 収集日時 |
|---|---|---|---|
| AWS 側 | `collect_blue_green_prereqs` | あり | 2026-09-17T00:00:00Z |
| 接続先の状態 | `collect_blue_mysql_state` | あり | 2026-09-17T00:05:00Z |
| アップグレードチェッカー | `collect_blue_upgrade_check` | あり | 2026-09-17T00:10:00Z |

### 注意点

- MySQL Shell のアップグレードチェッカーと RDS 組み込みのプリチェックは検査項目が一致しない。RDS 固有の項目（FLOAT / DOUBLE の AUTO_INCREMENT、非包摂的用語、memcached、空き容量、sys スキーマ）は Shell では出ないため、スナップショット復元機で試験アップグレードを 1 回通し `PrePatchCompatibility.log` を確認する
- このチェックは Blue/Green を**作成できるか**を見るものである。アプリケーションの互換性（実行 SQL・クライアントライブラリ）は移行ガイドの 0-4・0-5 で別に確認する

### 項目ごとの補足

| 判定 | 項目 | 合格条件 | 満たさないときの対処 | 参照 |
|---|---|---|---|---|
| PASS | 0-1-01 自動バックアップ | `BackupRetentionPeriod` が 1 以上 | 自動バックアップを有効化し、設定が反映されるまで待つ | `docs/phase-0-precheck.md` |
| REVIEW | 0-1-02 binlog_format | 値を記録する（Blue/Green の作成に `ROW` は必須ではない） | Blue を `ROW` に統一する場合は、移行と分離した運用判断として扱う。パラメータグループの値と実効値が違えば、適用待ち（再起動）や上書きの有無を確認する | `docs/decisions/binlog-format-bluegreen-compatibility.md` |
| PASS | 0-1-05 パラメータ適用状態 | `ParameterApplyStatus` が `in-sync` | `pending-reboot` 等なら、必要なパラメータ反映（再起動）を完了する | `docs/phase-0-precheck.md` |
| PASS | 0-1-03 オプショングループ | メジャーアップグレードの Blue/Green で使えるデフォルトのオプショングループ | カスタムグループを使っている場合は、デフォルトへ戻す影響を確認・解消する | `docs/phase-0-precheck.md` |
| PASS | 0-1-04 MEMCACHED | `MEMCACHED` が無い | 利用停止・アプリ設定変更・オプショングループ変更を先に完了する（memcached は 8.3 で廃止） | `docs/phase-0-precheck.md` |
| PASS | 0-1-06 外部 binlog レプリカ | `SHOW REPLICA STATUS` が空（Blue が外部からの binlog レプリカではない） | 外部レプリカの場合は構成を解消するか、移行方式を再検討する。未収集なら `collect_blue_mysql_state` で取得するか手で `SHOW REPLICA STATUS\G` を確認する | `docs/phase-0-precheck.md` |
| PASS | 0-1-07 カスケードリードレプリカ | カスケード構成（レプリカの配下のレプリカ）が無い | 該当する場合は構成を解消する | `docs/phase-0-precheck.md` |
| PASS | 0-1-08 インスタンスクラス | MySQL 8.4 を作成できる current / latest-generation のクラス | 前世代クラスは、Blue/Green 作成前にクラス変更を完了する | `docs/phase-0-precheck.md` |
| PASS | 0-1-09 空きストレージ | アップグレード・検証中に逼迫しない空き容量（目安 2 GiB 以上） | 不足時は空き容量を確保する。メトリクスが無ければ CloudWatch で直近の値を確認する | `docs/phase-0-precheck.md` |
| PASS | 0-1-10 Secrets Manager 管理パスワード | 利用していない、または Blue/Green の制約と一時解除・再設定の手順を確認済み | Secrets Manager 管理パスワードの制約を確認し、手順を用意する | `docs/phase-0-precheck.md` |
| PASS | 0-1-11 Zero-ETL 統合 | 利用していない、または Blue/Green の制約と一時解除・再設定の手順を確認済み | Zero-ETL 統合の制約を確認し、手順を用意する | `docs/phase-0-precheck.md` |
| PASS | 0-1-12 クロスリージョンリードレプリカ | 利用していない、または Blue/Green の制約と一時解除・再設定の手順を確認済み | クロスリージョンリードレプリカの扱いを確認し、手順を用意する | `docs/phase-0-precheck.md` |
| PASS | 0-1-13 RDS Proxy | Proxy が無い、または Blue が事前に対象 Proxy へ登録済み | Blue/Green 作成後は新規登録できないため、作成前に登録し、制約を関係者と共有する | `docs/phase-0-precheck.md` |
| PASS | 0-1-14 IAM DB 認証 | 無効、または切替後の Green 用 DB リソース ID / ARN を IAM ポリシーへ追加する手順と権限が準備済み | IAM ポリシーの更新手順を用意する | `docs/phase-0-precheck.md` |
| PASS | 0-2 InnoDB 以外のテーブル | ユーザースキーマに InnoDB 以外のテーブルが無い（`mysql` スキーマのシステムテーブルは対象外） | MyISAM は binlog レプリケーションで整合性が保証されないため `ALTER TABLE <db>.<table> ENGINE=InnoDB` で変換する。それ以外のエンジンは用途を確認する | `docs/rds-mysql-84-migration-guide.md の 0-2` |
| REVIEW | 0-3 アップグレードチェッカー | MySQL Shell のアップグレードチェッカーで Error が 0 件（Warning は個別判断） | Error は移行ガイドの対処表に従って解消する。**本番ではなくスナップショット復元機で実行し**、RDS 固有の項目は試験アップグレードの `PrePatchCompatibility.log` で確認する | `docs/rds-mysql-84-migration-guide.md の 0-3` |

## この結果の読み方

- **STOP が 1 件でも残る間は移行できない。**先に解消する
- **REVIEW は自動判定では決められない項目である。**人が確認して可否を決める
- このレポートは収集済み JSON だけから作る。**AWS へは接続していない**ため、
  収集時点（上記の収集日時）の状態を示す。時間が空いたら再収集する
- 項目の採番は `docs/phase-0-precheck.md` のチェックリストに対応する
- MySQL 側の収集（接続先の状態・アップグレードチェッカー）が無い場合、関わる項目は REVIEW（未収集）になり、該当する節は「省略した」と明示している

この結果をもとに、**移行できるか・どのインスタンスを対象にするか**を判断する。
対象を決めたら次は移行設定の生成とそのレビューへ進む（`report-generation-flows.md`）。
