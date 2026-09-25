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

## MySQL 側の収集結果

Blue へ接続して集めた、AWS API では見えない情報である。**判定（PASS / REVIEW / STOP）には使っていない。**人がここを見て、0-1-06 などの手動確認の根拠にする。

### 接続先の状態（`blue-mysql-state.json`）

| 項目 | 値 |
|---|---|
| 収集日時 | 2026-08-25T00:05:00Z |
| 接続先 | `example-service-production-mysql80.xxxxxxxxxxxx.ap-northeast-1.rds.amazonaws.com:3306` |
| MySQL バージョン | 8.0.39 |
| binlog_format（実効値） | MIXED |
| SHOW REPLICA STATUS | 0 行 |
| InnoDB 以外のテーブル | 1 件 |

**SHOW REPLICA STATUS**（0-1-06 外部 binlog レプリカ。空なら Blue はレプリカではない）

空（レプリケーションの受け側になっていない）。

**InnoDB 以外のテーブル**（ユーザースキーマ。MyISAM は Blue/Green のレプリケーションで整合性が保証されない）

| スキーマ | テーブル | エンジン |
|---|---|---|
| app | legacy | MyISAM |

### MySQL Shell アップグレードチェッカー（`blue-upgrade-check.json`）

| 項目 | 値 |
|---|---|
| 収集日時 | 2026-08-25T00:10:00Z |
| 接続先 | `example-service-production-mysql80.xxxxxxxxxxxx.ap-northeast-1.rds.amazonaws.com:3306` |
| サーバー | 8.0.39 - Source distribution |
| 移行先バージョン | 8.4.9 |
| Error / Warning / Notice | 0 / 20 / 2 |
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

## REVIEW — 人の確認が要る

- **0-1-02 binlog_format** … MIXED（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断）（`db-parameters.json`）
- **0-1-06 外部 binlog レプリカ** … AWS CLI のみでは判定不可。SHOW REPLICA STATUS\G の結果が空であることを手動確認（`手動確認（収集対象外）`）

## この結果の読み方

- **STOP が 1 件でも残る間は移行できない。**先に解消する
- **REVIEW は自動判定では決められない項目である。**人が確認して可否を決める
- このレポートは収集済み JSON だけから作る。**AWS へは接続していない**ため、
  収集時点（上記の収集日時）の状態を示す。時間が空いたら再収集する
- 項目の採番は `docs/phase-0-precheck.md` のチェックリストに対応する
- MySQL 側の収集結果は判定に使っていない。ファイルが無い節は「省略した」と明示している

この結果をもとに、**移行できるか・どのインスタンスを対象にするか**を判断する。
対象を決めたら次は移行設定の生成とそのレビューへ進む（`report-generation-flows.md`）。
