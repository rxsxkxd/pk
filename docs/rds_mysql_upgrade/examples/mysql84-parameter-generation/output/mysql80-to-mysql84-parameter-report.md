# MySQL 8.0 → 8.4 パラメータ移行レポート

- Source parameter group: `sample-production-mysql80` (`mysql8.0`)
- Source group apply status: `in-sync`
- Collected at: `2026-08-25T00:00:00Z`
- Rules: `config/mysql80-to-84-parameter-rules.yml`
- Generated parameters: `5`

## 値の由来

- **8.0 engine default**: `describe-engine-default-parameters --db-parameter-group-family mysql8.0` が返すファミリーの既定値。`Source=system` の実効値ではない。
- **8.0 Source=system**: `describe-db-parameters --source system` が現行カスタムグループについて返す、値の由来が RDS system であるパラメータ。該当値がない場合は `なし`、旧形式の入力で未収集の場合は `未収集` と表示する。
- **8.0 Source=user**: `describe-db-parameters --source user` が返す明示設定値。
- **8.4 engine default**: `describe-engine-default-parameters --db-parameter-group-family mysql8.4` が返すファミリーの既定値。Phase 1 では 8.4 DB に未関連付けのため、8.4 の `Source=system` は未取得・未確定である。

## 1. 元の user 定義値

`describe-db-parameters --source user` で取得した、8.0 カスタムパラメータグループの明示設定値である。

| Parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | engine default との差分 |
|---|---|---|---|---|
| binlog_format | MIXED | MIXED | なし | engine default と同一 |
| default_authentication_plugin | mysql_native_password | mysql_native_password | なし | engine default と同一 |
| innodb_log_file_size | 536870912 | 134217728 | なし | engine default から上書き |
| log_slave_updates | 1 | 0 | なし | engine default から上書き |
| max_allowed_packet | 67108864 | 67108864 | なし | engine default と同一 |
| slave_parallel_workers | 8 | 4 | なし | engine default から上書き |

## 2. リネーム以外の値変更・新規追加パラメーター

名称変更（旧名から新名への `copy`）を除き、移行ルールに定義した値・仕様変更候補と MySQL 8.4 新規パラメーターを一覧化する。8.0 側で user 定義がない項目は、8.4 の既定値を採用するかをレビューする。

| 区分 | 8.0 parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | 8.4 parameter | 8.4 engine default | Rule | 処理結果 | 判断理由（8.0 時点を含む） |
|---|---|---|---|---|---|---|---|---|---|
| 値・仕様変更候補 | binlog_format | MIXED | MIXED | なし | binlog_format | ROW | force | 生成済み | MySQL 8.4 Green 側のログ形式を明示する運用方針（Blue/Green 作成の前提条件ではない） / 8.0: Source=user=MIXED（engine default と同一、Source=system=なし） |
| エンジン既定値・挙動変更 | group_replication_consistency |  |  | なし | group_replication_consistency |  | review | 8.0 user 定義なし | 8.4 の既定値変更による整合性・待機時間への影響を確認する / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| エンジン既定値・挙動変更 | group_replication_exit_state_action |  |  | なし | group_replication_exit_state_action |  | review | 8.0 user 定義なし | 8.4 の既定値変更による障害時の挙動を確認する / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| エンジン既定値・挙動変更 | innodb_adaptive_hash_index |  |  | なし | innodb_adaptive_hash_index |  | review | 8.0 user 定義なし | 8.4 の既定値 OFF と性能影響を Green で評価する / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| CPU・メモリ依存の既定値または算出方式 | innodb_buffer_pool_instances |  |  | なし | innodb_buffer_pool_instances |  | review | 8.0 user 定義なし | 8.4 では vCPU 数から算出される。8.0 の固定値を自動移植しない / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| RDS・インスタンスクラス依存の自動算出 | innodb_buffer_pool_size |  |  | なし | innodb_buffer_pool_size |  | review | 8.0 user 定義なし | 8.4 では innodb_dedicated_server によりメモリから算出される / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| エンジン既定値・挙動変更 | innodb_change_buffering |  |  | なし | innodb_change_buffering |  | review | 8.0 user 定義なし | 8.4 の既定値 none と性能影響を Green で評価する / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| RDS・インスタンスクラス依存の自動算出 | innodb_dedicated_server |  |  | なし | innodb_dedicated_server |  | review | 8.0 user 定義なし | 8.4 では既定有効。関連する InnoDB 値の自動算出を確認する / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| エンジン既定値・挙動変更 | innodb_io_capacity |  |  | なし | innodb_io_capacity |  | review | 8.0 user 定義なし | 8.4 の既定値は 10000。ストレージ IOPS と負荷試験で判断する / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| エンジン既定値・挙動変更 | innodb_io_capacity_max |  |  | なし | innodb_io_capacity_max |  | review | 8.0 user 定義なし | 8.4 では innodb_io_capacity に連動する。固定値を自動移植しない / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| 廃止・代替 | innodb_log_file_size | 536870912 | 134217728 | なし | innodb_log_file_size |  | omit | 設定対象外 | MySQL 8.4 では innodb_redo_log_capacity を使用。個別の容量設計は別途レビューする。 / 8.0: Source=user=536870912（engine default=134217728、Source=system=なし） |
| 廃止・代替 | innodb_log_files_in_group |  |  | なし | innodb_log_files_in_group |  | omit | 8.0 user 定義なし | MySQL 8.4 では innodb_redo_log_capacity を使用。個別の容量設計は別途レビューする。 / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| エンジン既定値・挙動変更 | innodb_numa_interleave |  |  | なし | innodb_numa_interleave |  | review | 8.0 user 定義なし | 8.4 の既定値 ON。インスタンスクラスと性能影響を確認する / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| エンジン既定値・挙動変更 | innodb_page_cleaners |  |  | なし | innodb_page_cleaners |  | review | 8.0 user 定義なし | 8.4 では innodb_buffer_pool_instances に連動する / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| CPU・メモリ依存の既定値または算出方式 | innodb_parallel_read_threads |  |  | なし | innodb_parallel_read_threads |  | review | 8.0 user 定義なし | 8.4 では vCPU 数から算出される / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| CPU・メモリ依存の既定値または算出方式 | innodb_purge_threads |  |  | なし | innodb_purge_threads |  | review | 8.0 user 定義なし | 8.4 では vCPU 数から算出される / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| CPU・メモリ依存の既定値または算出方式 | innodb_read_io_threads |  |  | なし | innodb_read_io_threads |  | review | 8.0 user 定義なし | 8.4 では vCPU 数から算出される / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| RDS・インスタンスクラス依存の自動算出 | innodb_redo_log_capacity |  |  | なし | innodb_redo_log_capacity |  | review | 8.0 user 定義なし | 8.4 では innodb_dedicated_server によりメモリから算出される / 8.0: Source=user なし（engine default=取得なし、Source=system=なし） |
| 8.4 新規 | restrict_fk_on_non_standard_key | (8.4 新規) |  | なし | restrict_fk_on_non_standard_key | ON | review | 要レビュー | 新規パラメータ。非標準キーを参照する外部キー DDL の有無を確認する / 8.0: パラメーターなし（8.4 新規） |

## 3. 移行処理結果

収集された user 定義と `target_only` ルールを、生成可否まで含めて記録する。未登録の user 定義は、8.4 に同名で存在し変更可能なら同じ値を生成し、それ以外は「生成不可」として検出する。

| Source parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | 8.4 target | 8.4 engine default | 8.4 allowed / apply | Rule | 処理結果 | 判断理由 |
|---|---|---|---|---|---|---|---|---|---|
| binlog_format | MIXED | MIXED | なし | binlog_format | ROW | ROW,MIXED,STATEMENT / dynamic | force | 生成済み | MySQL 8.4 Green 側のログ形式を明示する運用方針（Blue/Green 作成の前提条件ではない） |
| default_authentication_plugin | mysql_native_password | mysql_native_password | なし | authentication_policy | *, | * / dynamic | force | 生成済み | mysql_native_password を許可し第1認証要素の既定にする。8.4 でのプラグイン利用可否は Green で接続試験する |
| innodb_log_file_size | 536870912 | 134217728 | なし | innodb_log_file_size |  |  | omit | 設定対象外 | MySQL 8.4 では innodb_redo_log_capacity を使用。個別の容量設計は別途レビューする。 |
| log_slave_updates | 1 | 0 | なし | log_replica_updates | 0 | 0,1 / dynamic | copy | 生成済み | MySQL 8.4 での名称変更 |
| max_allowed_packet | 67108864 | 67108864 | なし | max_allowed_packet | 67108864 | 1024-1073741824 / dynamic | copy | 生成済み | 移行ルール未登録。Source=user の値を同名で反映する |
| restrict_fk_on_non_standard_key | (8.4 新規) |  | なし | restrict_fk_on_non_standard_key | ON | ON,OFF / dynamic | review | 要レビュー | 新規パラメータ。非標準キーを参照する外部キー DDL の有無を確認する |
| slave_parallel_workers | 8 | 4 | なし | replica_parallel_workers | 4 | 0-1024 / dynamic | copy | 生成済み | MySQL 8.4 での名称変更 |

## 判定

- 生成不可: 0
- 要レビュー: 1
「要レビュー」または「生成不可」が残る場合、生成 YAML をデプロイしない。ルールを更新して再生成する。
