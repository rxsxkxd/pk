# RDS for MySQL 8.0 → 8.4 移行手順書（Blue/Green Deployments）

> 対象: Amazon RDS for MySQL 8.0.x → 8.4.x（LTS）
> 方式: RDS Blue/Green Deployments
> 期限: **2026-07-31（8.0 標準サポート終了）** ／ 8/1 以降は Extended Support が自動課金

---

## 0. 全体像

| フェーズ | 内容 | 本番影響 | 目安時間 |
|---|---|---|---|
| Phase 0 | 事前棚卸し・プリチェック | なし（スナップショット復元機で実施） | 半日〜数日 |
| Phase 1 | 8.4 用パラメータグループ作成／8.0 側の前提設定 | ほぼなし（動的パラメータ） | 1 時間 |
| Phase 2 | Blue/Green 作成 → Green を 8.4 化 | なし | 20〜60 分 |
| Phase 3 | Green 検証 ＋ 切り戻し経路の準備 | なし | 1〜2 時間 |
| Phase 4 | スイッチオーバー | **瞬断（数秒〜1 分未満）** | 数分 |
| Phase 5 | 切替後ヘルスチェック → 後始末 | なし | 数日運用後に削除 |

---

# 1. 新環境（Green）の構築手順

## Phase 0 — 事前棚卸し・プリチェック

### 0-1. Blue/Green の成立条件を確認

満たしていないと **作成リクエスト自体が弾かれる**ため最初に確認する。

- [ ] 自動バックアップが有効（`backup_retention_period >= 1`）
- [ ] `binlog_format = ROW`（エンジンデフォルトの `MIXED` では不可）
- [ ] **デフォルトのオプショングループ**を使用している
      - メジャーアップの Blue/Green は「default option groups のみ対応」。中身が空のカスタム OG なら default に戻す
      - `memcached` オプションが入っている場合は 8.4 で廃止のため必ず外す
- [ ] 外部 binlog レプリカではない（`SHOW REPLICA STATUS\G` が空）
- [ ] カスケードリードレプリカが存在しない
- [ ] パラメータグループのステータスが `In Sync`
- [ ] 空きストレージが 2 GiB 以上
- [ ] Secrets Manager マネージドパスワード / Zero-ETL / クロスリージョンリードレプリカ を使っていない（使用中なら一時解除）
- [ ] **インスタンスクラスが latest-generation / current-generation であること**（MySQL 5.7/8.0/8.4 は前世代クラスでの作成不可。前世代のままだと Blue/Green 作成自体が失敗するため、先に `modify-db-instance` でクラス変更が必要）
- [ ] RDS Proxy を使っている場合、Blue を事前にプロキシへ登録済みであること（Blue/Green 作成後の新規登録はブロックされる。既存デプロイがある状態での登録もブロックされる）
- [ ] IAM データベース認証を使っている場合、切替後に Green へ接続できるよう、IAM ポリシーの `Resource` に Blue・Green 双方の ARN を含めておく（Green 用に後から追加が必要）

```bash
# 明示的に変更しているパラメータの洗い出し
aws rds describe-db-parameters \
  --db-parameter-group-name <current-pg> \
  --query "Parameters[?Source=='user'].[ParameterName,ParameterValue,Source]" \
  --output table
```

### 0-2. ストレージエンジンの棚卸し（MyISAM 撲滅）

Blue/Green は binlog レプリケーション前提。非トランザクションの MyISAM は整合性が保証されない。

```sql
SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE
FROM information_schema.TABLES
WHERE ENGINE <> 'InnoDB'
  AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema');

-- 該当があれば
ALTER TABLE <db>.<table> ENGINE=InnoDB;
```

※ `mysql` スキーマのシステムテーブルが MyISAM なのは正常。ユーザースキーマのみ対象。

### 0-3. MySQL Shell アップグレードチェッカー

**本番に対しては実行しない。** メタデータの全走査が走るため、スナップショットから復元した検証機に対して実行する。

```bash
# RELOAD, PROCESS, SELECT 権限が必要
mysqlsh -- util check-for-server-upgrade \
  --user=<user> --host=<restored-instance-endpoint> --port=3306 \
  --target-version=8.4.9
```

判定は Error（アップグレードを阻害）／ Warning（個別判断）／ Notice（情報）の 3 段階。

**Error になりやすい項目と対処:**

| 検出項目 | 内容 | 対処 |
|---|---|---|
| AUTO_INCREMENT on FLOAT/DOUBLE | 8.4 で禁止 | カラム型を `BIGINT` 等の整数型へ変更 |
| 非包摂的用語の使用 | ストアド／ビュー内の `MASTER` / `SLAVE` | `SOURCE` / `REPLICA` へ書き換え。`SHOW MASTER STATUS` → `SHOW BINARY LOG STATUS`、`SHOW SLAVE STATUS` → `SHOW REPLICA STATUS` |
| KEY パーティション + プレフィックスインデックス | `KEY(col(10))` 等が 8.4 で不許可 | プレフィックスを外す or RANGE / HASH へ再設計 |
| `check table for upgrade` が Corrupt | 壊れたビュー／不正参照 | 該当ビューを DROP または再作成 |
| system variable の不許可値 | 例: `ssl_cipher` に旧 cipher 指定 | 許可値へ変更 |
| sys スキーマ内のユーザー作成テーブル | 衝突の可能性 | 退避して削除 |
| memcached プラグイン | 8.3 で廃止 | オプショングループから MEMCACHED を削除 |

```sql
-- 非包摂的用語を含むストアドの検出
SELECT ROUTINE_SCHEMA, ROUTINE_NAME
FROM information_schema.ROUTINES
WHERE ROUTINE_DEFINITION REGEXP 'MASTER|SLAVE';
```

> **注意:** MySQL Shell と RDS 組み込みプリチェックはチェック項目が一致しない。RDS 固有項目（FLOAT/DOUBLE の AUTO_INCREMENT、非包摂的用語、memcached、空き容量、sys スキーマ）は Shell では出ないので、**スナップショット復元機で試験アップグレードを 1 回通し、`PrePatchCompatibility.log` を確認する**のが確実。

### 0-4. 実行 SQL の棚卸し

8.4 化前にできるのは「洗い出し」まで。実測は Phase 3 で行う。

- [ ] スロークエリログから重い一覧・検索・レポート系クエリを抽出（8.4 はオプティマイザの挙動が一部変わる）
- [ ] 予約語の追加（`MANUAL`, `PARALLEL`, `QUALIFY`, `TABLESAMPLE` 等）とクォートなし識別子の衝突を確認
- [ ] `SHOW MASTER STATUS` / `SHOW SLAVE STATUS` / `CHANGE MASTER TO` / `START SLAVE` 等を叩いている監視スクリプト・運用ツールの洗い出し（**8.4 で削除済み**）
- [ ] `WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS()` の使用有無
- [ ] 部分インデックス／非ユニークキーへの外部キー作成を実行時に行っていないか（後述 `restrict_fk_on_non_standard_key`）

### 0-5. クライアントライブラリの検証

**ここが最も見落とされやすい。** 8.4 のデフォルト認証プラグインは `caching_sha2_password` になる。

```sql
-- native 認証のユーザー一覧
SELECT user, host, plugin FROM mysql.user
WHERE plugin = 'mysql_native_password';
```

- 既存の `mysql_native_password` ユーザーは**アップグレード後もそのまま接続できる**（RDS for MySQL 8.4 では引き続き動作する。ただし [AWS公式](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.KnownIssuesAndLimitations.html) は「support of this plugin ends with MySQL 8.4」と明記しており、**次のメジャーバージョンでは廃止される想定**。移行を機に `caching_sha2_password` への切り替えも中期的に計画しておくとよい）
- ただし **新規作成ユーザーは `caching_sha2_password` になる**
- 古いドライバは `Authentication plugin 'caching_sha2_password' cannot be loaded` で接続失敗する

| ドライバ | 最低要件バージョン |
|---|---|
| Java MySQL Connector/J | 8.0.9 |
| Python PyMySQL | 0.9.0 |
| Go MySQL Driver | 1.4.0 |
| PHP mysqli / PDO | 7.4.4 |
| Ruby mysql2 gem（Rails ActiveRecord） | 0.5.0 以上（gem 単体のバージョンに加え、リンクしている `libmysqlclient` / `mariadb-connector-c` 側も caching_sha2_password 対応版である必要あり。`bundle exec ruby -e "require 'mysql2'; puts Mysql2::VERSION"` と `ldd $(bundle show mysql2)/lib/mysql2/mysql2.so \| grep -i mysql` 等でリンク先ライブラリも確認） |

- [ ] 対象 DB に接続している経路をすべて洗い出す（アプリ、バッチ、BI、監視、踏み台からの手動接続）
- [ ] 各経路のクライアントライブラリバージョンを確認
- [ ] コネクションプールが再接続／リトライに対応しているか確認（切替時の 1 リクエスト失敗を吸収できるか）
- [ ] TLS が 1.2 / 1.3 のみになる点を確認（8.4 の RDS は OpenSSL → AWS-LC に置換済み）
- [ ] DNS キャッシュの TTL が 5 秒以下、またはアプリ側で DNS をキャッシュしていないこと

### 0-6. インスタンスタイプの検証（サイズ変更は任意／世代確認は必須）

**世代の確認は 0-1 の成立条件チェックに含まれる必須項目。** MySQL 5.7/8.0/8.4 のDBインスタンスは latest-generation / current-generation のインスタンスクラスでのみ作成できる（[AWS公式](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.MySQL.Major.html)）。t2 / m4 / r4 系などの前世代クラスを使い続けている環境が対象に残っていないか確認し、該当があれば Blue/Green 作成前に現行世代クラスへ変更しておく。

一方でサイズ変更（インスタンスクラスの大小）自体は、Blue/Green ではデフォルトで Blue と同構成の Green が作られるため**必須工程ではない**。ただし 8.4 では以下が効いてくるため、この機会に見直す価値はある。

- `innodb_dedicated_server` が **デフォルト ON** になり、`innodb_buffer_pool_size` と `innodb_redo_log_capacity` がインスタンスクラスのメモリから自動算出される
  - メモリ < 1 GB → 128 MB ／ 1〜4 GB → メモリ × 0.5 ／ > 4 GB → メモリ × 0.75
- `innodb_buffer_pool_instances` / `innodb_page_cleaners` / `innodb_parallel_read_threads` / `innodb_read_io_threads` / `innodb_purge_threads` が **vCPU 数の関数**になる（下表参照）→ vCPU が少ないインスタンスほど値が下がる
- サイズ変更を同時に行う場合は `--target-db-instance-class` を指定するが、**変数を増やすとトラブル切り分けが難しくなる**ので、原則はバージョンアップ単独で通し、リサイズは切替後に別作業とするのを推奨

> なお Extended Support 課金は vCPU 時間単価のため、micro 〜 large はいずれも 2 vCPU で**同額**。「小さいから安い」は成立しない。

---

## Phase 1 — パラメータグループの準備

### 1-1. Blue（8.0）側

```bash
# binlog_format = ROW（動的パラメータ。再起動不要）
aws rds modify-db-parameter-group \
  --db-parameter-group-name <current-pg> \
  --parameters "ParameterName=binlog_format,ParameterValue=ROW,ApplyMethod=immediate"
```

```sql
-- 実効値の確認
SHOW VARIABLES LIKE 'binlog_format';   -- ROW

-- 切り戻し経路を用意するなら binlog 保持を 24 時間以上に
CALL mysql.rds_set_configuration('binlog retention hours', 24);
CALL mysql.rds_show_configuration;
```

### 1-2. Green（8.4）用パラメータグループの新規作成

**パラメータグループはファミリーをまたげないため、`mysql8.4` ファミリーで作り直しが必須。**

```bash
aws rds create-db-parameter-group \
  --db-parameter-group-name <name>-mysql84 \
  --db-parameter-group-family mysql8.4 \
  --description "MySQL 8.4 for <system>"

aws rds modify-db-parameter-group \
  --db-parameter-group-name <name>-mysql84 \
  --parameters "ParameterName=binlog_format,ParameterValue=ROW,ApplyMethod=immediate"
```

Phase 0-1 で洗い出した `Source=='user'` のパラメータを、**次章の差分表と突き合わせながら**移植する。

### 1-3. 保護スナップショットの取得

```bash
aws rds create-db-snapshot \
  --db-instance-identifier <blue-instance-id> \
  --db-snapshot-identifier <blue-instance-id>-pre84-$(date +%Y%m%d)
```

---

## Phase 2 — Blue/Green デプロイの作成と Green の 8.4 化

### 方式 A（AWS 推奨）: 同一バージョンで作成 → 手動で 8.4 化

```bash
# 1. Blue と同じ 8.0.x で Blue/Green を作成
aws rds create-blue-green-deployment \
  --blue-green-deployment-name <name>-84-bg \
  --source <blue-db-arn> \
  --target-engine-version 8.0.44

# 2. 作成完了後、Green インスタンスだけを 8.4.9 へ手動アップグレード
aws rds modify-db-instance \
  --db-instance-identifier <green-instance-id> \
  --engine-version 8.4.9 \
  --db-parameter-group-name <name>-mysql84 \
  --allow-major-version-upgrade \
  --apply-immediately
```

**この方式を推奨する理由:** 作成時に一気に 8.4 を指定すると、自動アップグレードが失敗した場合に **Blue/Green デプロイごと作り直し**になる。段階を分ければ、失敗しても Green のアップグレードだけリトライできる。

### 方式 B（ワンショット）: 作成時に 8.4 を指定

```bash
aws rds create-blue-green-deployment \
  --blue-green-deployment-name <name>-84-bg \
  --source <blue-db-arn> \
  --target-engine-version 8.4.9 \
  --target-db-parameter-group-name <name>-mysql84
```

手数は少ないが、上記のリスクを許容できる場合のみ。

### 進行の確認

1. Green がリードレプリカとして作成され、Blue → Green のレプリケーションが確立
2. Green だけが 8.4.9 へアップグレードされる（アクセスは Blue のままなので本番影響なし）
3. Green のバックアップが設定され、デプロイ全体が `AVAILABLE` になる

```bash
aws rds describe-blue-green-deployments \
  --blue-green-deployment-identifier <bgd-id> \
  --query 'BlueGreenDeployments[0].[Status,StatusDetails]'
```

失敗した場合は Green インスタンスの `PrePatchCompatibility.log` と「最近のイベント」を確認する。

---

# 2. パラメータグループ差分（8.0 → 8.4）

## 2-1. RDS のパラメータグループから **削除**されたもの

| 削除されたパラメータ | 代替 |
|---|---|
| `innodb_log_file_size` | `innodb_redo_log_capacity`（エンジンが自動算出。上書き可） |
| `innodb_log_files_in_group` | 同上 |

8.0 のカスタム PG でこれらを明示指定していた場合、**8.4 の PG には移植できない**。REDO ログのサイジングは `innodb_redo_log_capacity` に読み替える。

## 2-2. **リネーム**されたパラメータ（非包摂的用語の置換）

8.4 のカスタム PG では **新名称でしか値を変更できない**（`mysql` クライアントからの参照は旧名でも可）。

| 旧名 | 新名 |
|---|---|
| `init_slave` | `init_replica` |
| `log_slave_updates` | `log_replica_updates` |
| `log_slow_slave_statements` | `log_slow_replica_statements` |
| `rpl_stop_slave_timeout` | `rpl_stop_replica_timeout` |
| `skip_slave_start` | `skip_replica_start` |
| `slave_checkpoint_group` | `replica_checkpoint_group` |
| `slave_checkpoint_period` | `replica_checkpoint_period` |
| `slave_compressed_protocol` | `replica_compressed_protocol` |
| `slave_exec_mode` | `replica_exec_mode` |
| `slave_load_tmpdir` | `replica_load_tmpdir` |
| `slave_max_allowed_packet` | `replica_max_allowed_packet` |
| `slave_net_timeout` | `replica_net_timeout` |
| `slave_parallel_type` | `replica_parallel_type` |
| `slave_parallel_workers` | `replica_parallel_workers` |
| `slave_pending_jobs_size_max` | `replica_pending_jobs_size_max` |
| `slave_preserve_commit_order` | `replica_preserve_commit_order` |
| `slave_skip_errors` | `replica_skip_errors` |
| `slave_sql_verify_checksum` | `replica_sql_verify_checksum` |
| `slave_transaction_retries` | `replica_transaction_retries` |
| `slave_type_conversions` | `replica_type_conversions` |
| `sql_slave_skip_counter` | `sql_replica_skip_counter` |

※ `replica_allow_batching` は RDS が NDB クラスタ非対応のため提供されない。

**ストアドプロシージャも同様にリネーム**（8.4 初回リリース時点では旧名も使用可、将来削除予定）:

| 旧名 | 新名 |
|---|---|
| `mysql.rds_next_master_log` | `mysql.rds_next_source_log` |
| `mysql.rds_reset_external_master` | `mysql.rds_reset_external_source` |
| `mysql.rds_set_external_master` | `mysql.rds_set_external_source` |
| `mysql.rds_set_external_master_with_auto_position` | `mysql.rds_set_external_source_with_auto_position` |
| `mysql.rds_set_external_master_with_delay` | `mysql.rds_set_external_source_with_delay` |
| `mysql.rds_set_master_auto_position` | `mysql.rds_set_source_auto_position` |

## 2-3. **追加**されたパラメータ

| パラメータ | 既定値 | 内容 |
|---|---|---|
| `restrict_fk_on_non_standard_key` | **ON** | 非ユニークキー／部分キーに対する外部キーの作成（`CREATE TABLE` / `ALTER TABLE`）をブロックする。**既存の外部キーやアップグレード自体には影響しない**が、アプリが実行時に FK を作成・変更する場合は `OFF` にするか DDL を修正する |
| `authentication_policy` | `*,,` 相当（既定 `caching_sha2_password`） | `default_authentication_plugin` の後継。8.4 では `default_authentication_plugin` 自体が**削除**されている |

## 2-4. **デフォルト値が変更**されたパラメータ（RDS 8.4 PG で変更可能なもの）

8.0 側で明示設定していた場合は、8.4 に持ち越すべきか個別に判断すること。

| パラメータ | 8.0 既定 | 8.4 既定 |
|---|---|---|
| `innodb_adaptive_hash_index` | ON | **OFF** |
| `innodb_buffer_pool_instances` | 8（buffer_pool < 1GB なら 1） | `MAX(1, vCPU/4)` |
| `innodb_change_buffering` | all | **none** |
| `innodb_io_capacity` | 200 | **10000** |
| `innodb_io_capacity_max` | 200 | `2 × innodb_io_capacity` |
| `innodb_numa_interleave` | OFF | ON |
| `innodb_page_cleaners` | 4 | `innodb_buffer_pool_instances` |
| `innodb_parallel_read_threads` | 4 | `MAX(vCPU/8, 4)` |
| `innodb_read_io_threads` | 4 | `MAX(vCPU/2, 4)` |
| `group_replication_consistency` | EVENTUAL | BEFORE_ON_PRIMARY_FAILOVER |
| `group_replication_exit_state_action` | READ_ONLY | OFFLINE_MODE |

**RDS 固有のデフォルト変更:**

| パラメータ | 8.4 での挙動 |
|---|---|
| `innodb_dedicated_server` | **デフォルト有効**。`innodb_buffer_pool_size` と `innodb_redo_log_capacity` をインスタンスクラスのメモリから自動算出 |
| `innodb_buffer_pool_size` | エンジンが算出（上書き可）。メモリ < 1GB → 128MB ／ 1〜4GB → ×0.5 ／ > 4GB → ×0.75 |
| `innodb_redo_log_capacity` | エンジンが算出（上書き可） |
| `innodb_purge_threads` | `LEAST(vCPU/2, 4)`（InnoDB history list 肥大化防止） |
| `binlog_format` | **既定が ROW** に変更（コミュニティ既定に整合） |

> **性能面の注意:** `innodb_adaptive_hash_index=OFF` と `innodb_change_buffering=none` は、8.0 でこれらに依存していたワークロードで性能が変わり得る。逆に `innodb_io_capacity` の 200 → 10000 は、gp2 のような低 IOPS ストレージでは過剰なフラッシュを招く可能性がある。**本番相当の負荷で計測してから移行する**こと。

## 2-5. その他の非パラメータ系変更

| 項目 | 内容 |
|---|---|
| 暗号ライブラリ | OpenSSL → **AWS-LC**（FIPS 140-3 認証） |
| TLS | **1.2 / 1.3 のみ**サポート |
| memcached | 8.4 で提供終了（オプショングループから削除必須） |
| `mysqlpump` | 8.4 で削除。`mysqldump` または MySQL Shell dump utility を使用 |
| `mysql_upgrade` | 削除（初回起動時に自動実行） |
| レプリケーション用ストアド | `caching_sha2_password` のレプリケーションユーザーを使う場合、`SOURCE_SSL=1` の指定が必須 |

---

# 3. 動作検証チェックリスト

## 3-1. Phase 3: Green の検証（切替前 / 本番影響なし）

Green のエンドポイントに直接接続して確認する。ここで問題が見つかっても、本番は Blue で動いているため落ち着いて対処できる。

### バージョン・基本設定

```sql
SELECT VERSION();                       -- 8.4.9
SHOW VARIABLES LIKE 'binlog_format';    -- ROW
SHOW VARIABLES LIKE 'innodb_dedicated_server';
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
SHOW VARIABLES LIKE 'innodb_redo_log_capacity';
SHOW VARIABLES LIKE 'authentication_policy';
SHOW VARIABLES LIKE 'restrict_fk_on_non_standard_key';
```

- [ ] エンジンバージョンが 8.4.9
- [ ] 意図した 8.4 用パラメータグループが `In Sync` で適用されている
- [ ] 2-4 の差分表のうち、8.0 で明示設定していた値が意図どおり反映されている

### データ整合性

```sql
-- 全テーブルが InnoDB
SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE
FROM information_schema.TABLES
WHERE ENGINE <> 'InnoDB'
  AND TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema');

-- レプリケーション追従
SHOW REPLICA STATUS\G
--   Replica_IO_Running:  Yes
--   Replica_SQL_Running: Yes
--   Seconds_Behind_Source: 0
```

- [ ] ユーザースキーマに MyISAM が残っていない
- [ ] レプリ遅延ゼロ、IO / SQL スレッドともに Yes
- [ ] 主要テーブルの件数が Blue と一致（`SELECT COUNT(*)` を主要テーブル分）
- [ ] ビュー・ストアドプロシージャ・トリガ・イベントの数が Blue と一致

```sql
SELECT ROUTINE_TYPE, COUNT(*) FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA NOT IN ('mysql','sys') GROUP BY ROUTINE_TYPE;
SELECT COUNT(*) FROM information_schema.TRIGGERS;
SELECT COUNT(*) FROM information_schema.EVENTS;
```

### 認証・接続

- [ ] 既存の native 認証ユーザーが Green にそのまま接続できる
- [ ] **各アプリのドライバから**実際に接続できる（ローカルの mysql クライアントだけで確認しない）
- [ ] TLS 1.2 / 1.3 で接続できる
- [ ] 新規ユーザーを作る運用がある場合、`caching_sha2_password` でアプリが接続できるか検証

```sql
SELECT user, host, plugin FROM mysql.user ORDER BY plugin;
```

### クエリ検証（ここが本番）

- [ ] Phase 0-4 で洗い出した重いクエリを Green に対して実行し、**実行計画と実行時間を Blue と比較**

```sql
-- 同じクエリを Blue / Green 双方で
EXPLAIN ANALYZE <重いクエリ>;
```

- [ ] 一覧・検索・レポート・集計系のプランが劣化していないこと
- [ ] インデックスが使われなくなった箇所がないこと（8.4 のオプティマイザ変更）
- [ ] アプリの主要ユースケースを Green 向けの接続先で一通り疎通（可能ならステージング環境の接続先を Green に切り替えて実施）
- [ ] バッチ・日次処理の代表的なものを Green で試験実行

### 運用ツール

- [ ] `SHOW MASTER STATUS` / `SHOW SLAVE STATUS` 等を叩く監視・オーケストレーションが 8.4 の新構文に対応済み
- [ ] バックアップ／エクスポート処理が `mysqlpump` に依存していない

## 3-2. Phase 3: 切り戻し経路の準備（任意だが推奨）

切替後に問題が発覚した場合に備え、**逆方向レプリケーション**（新 8.4 → 旧 8.0 `-old1`）を用意する。

- [ ] Blue / Green 双方で binlog 保持 24 時間以上を設定済み
- [ ] スイッチオーバー完了後の binlog ファイル名・ポジションを記録（RDS コンソール → ログとイベント → Binary log）
- [ ] 8.4 側にレプリケーションユーザーを作成し、`-old1` から `mysql.rds_set_external_source` で逆レプリを開始
- [ ] `-old1` の `read_only` は 0 に戻さなくてよい（ネイティブレプリケーションの場合）

> 逆レプリを張らない場合、切替後に新環境で書き込みが発生した時点で切り戻しは非現実的になる。保護スナップショットはより深い復元ポイントとして残しておく。

## 3-3. Phase 4: スイッチオーバー直前

- [ ] Green の `ReplicaLag` がほぼゼロ
- [ ] Blue に長時間実行中のクエリがない（`SHOW PROCESSLIST`）
- [ ] Blue / Green 双方が `Available`
- [ ] アプリが DNS をキャッシュしていない、または TTL が 5 秒以下
- [ ] 切り戻し準備が完了している
- [ ] アクセスの少ない時間帯である
- [ ] 関係者への周知・メンテナンス告知が済んでいる

```bash
aws rds switchover-blue-green-deployment \
  --blue-green-deployment-identifier <bgd-id> \
  --switchover-timeout 300
# Status: SWITCHOVER_IN_PROGRESS -> SWITCHOVER_COMPLETED
```

> `--switchover-timeout` は許容ダウンタイムに合わせる（最大 60 分）。この間、既存コネクションは切断される。切替時間が ALB のアイドルタイムアウト（既定 60 秒）や nginx のプロキシタイムアウト（既定 60 秒）より短ければ、エンドユーザーには「一瞬重かった」程度の待ち時間として吸収されることが多い。

## 3-4. Phase 5: 切替後のヘルスチェック

### 即時（切替後 5 分以内）

```sql
SELECT VERSION();                      -- 8.4.9
SELECT @@hostname, @@read_only;        -- read_only = 0
SHOW VARIABLES LIKE 'binlog_format';
```

- [ ] エンドポイント名が変わっていない
- [ ] 新インスタンスが書き込み可能（`read_only = 0`）
- [ ] 各アプリがログインできる
- [ ] 主要画面が表示される
- [ ] **代表的な書き込み処理が成功する**（読み取りだけで判定しない）
- [ ] アプリのエラーログに接続エラーが継続的に出ていない
- [ ] コネクションプールが正常に再接続している

### 短期（当日〜翌日）

- [ ] RDS のエラーログに新規異常がない
- [ ] スロークエリログに**新規に**出現したクエリがないか（プラン悪化の検出）
- [ ] CloudWatch メトリクスを切替前と比較
  - `CPUUtilization` / `DatabaseConnections` / `ReadIOPS` / `WriteIOPS`
  - `ReadLatency` / `WriteLatency`
  - `FreeableMemory`（`innodb_dedicated_server` によるバッファプール自動算出の影響）
- [ ] Performance Insights で上位クエリの傾向が切替前と大きく変わっていないか
- [ ] 日次・夜間バッチが正常完走した
- [ ] 自動バックアップが取得されている

### 中期（数日〜1 週間）

- [ ] 週次・月次バッチの完走
- [ ] リードレプリカを再作成した場合、その追従状況
- [ ] 逆レプリケーションのラグ（切り戻し経路を維持している間）

### 後始末

問題がないと判断できたら、二重課金を止める。

```bash
# 1. Blue/Green デプロイの削除（インスタンスは消えない）
aws rds delete-blue-green-deployment \
  --blue-green-deployment-identifier <bgd-id> \
  --no-delete-target

# 2. 逆レプリケーションの停止（張っていた場合）
#    CALL mysql.rds_stop_replication;  on -old1

# 3. 旧 Blue の削除（削除保護が ON なら先に解除）
aws rds modify-db-instance \
  --db-instance-identifier <blue-instance-id>-old1 \
  --no-deletion-protection \
  --apply-immediately

aws rds delete-db-instance \
  --db-instance-identifier <blue-instance-id>-old1 \
  --final-db-snapshot-identifier <blue-instance-id>-old1-final \
  --no-delete-automated-backups
```

- [ ] Blue/Green デプロイを削除
- [ ] 旧 Blue（`-old1`）を最終スナップショット付きで削除
- [ ] プリチェック用にスナップショット復元したインスタンスを削除
- [ ] プリチェック用 EC2 / 踏み台を削除
- [ ] （DMS を使った場合）タスク・エンドポイント・レプリケーションインスタンスを削除
- [ ] **RDS の Extended Support 課金が発生していないことを翌月の請求で確認**

---

# 4. 落とし穴まとめ

| # | 落とし穴 | 対処 |
|---|---|---|
| 1 | ユーザースキーマに MyISAM が残っていて Blue/Green が成立しない | 事前に `ALTER TABLE ... ENGINE=InnoDB` |
| 2 | カスタムオプショングループでメジャーアップの Blue/Green が弾かれる | 中身が空ならデフォルト OG に戻す。memcached が入っていれば必ず削除 |
| 3 | 旧 Blue の削除保護 ON で削除できない | `--no-deletion-protection` で解除してから削除 |
| 4 | 作成時に一気に 8.4 を指定して失敗し、デプロイごと作り直し | 同一バージョンで作成 → Green を手動アップグレード |
| 5 | パラメータグループはファミリーをまたげない | `mysql8.4` ファミリーで新規作成し、`Source=='user'` の値を移植 |
| 6 | 8.4 の新規ユーザーが `caching_sha2_password` になり古いドライバが接続不可 | ドライバの最低バージョンを事前確認。必要なら `authentication_policy` を調整 |
| 7 | 監視スクリプトの `SHOW SLAVE STATUS` が 8.4 で動かない | `SHOW REPLICA STATUS` へ書き換え |
| 8 | `innodb_io_capacity` が 200 → 10000 になり低 IOPS ストレージで過剰フラッシュ | 8.4 PG で明示的に抑える判断も検討 |
| 9 | `innodb_adaptive_hash_index` が OFF になり特定ワークロードで劣化 | Green で実測して必要なら ON に戻す |
| 10 | binlog が purge されて切り戻し経路を張れない | 事前に `binlog retention hours` を 24 以上に |
| 11 | 逆レプリを張らずに時間が経過し、切り戻し不能になる | 切替直後に逆レプリを確立するか、切り戻し不可を許容する判断を明示的に行う |
| 12 | Blue が前世代インスタンスクラス（t2/m4/r4 系等）のままで Blue/Green 作成が失敗する | 事前に `modify-db-instance` で latest-generation / current-generation クラスへ変更 |
| 13 | RDS Proxy を使っているのに未登録、または既存 Blue/Green デプロイがある状態で登録しようとしてブロックされる | Blue/Green 作成**前**に Blue をプロキシへ登録しておく |
| 14 | IAM データベース認証利用時、切替後に Green への接続で認可エラーになる | IAM ポリシーの `Resource` に Green の ARN も事前に追加しておく |

---

# 5. 出典

- MOOBON 技術ブログ「RDS for MySQL 8.0 の延長サポートは割高 ── 標準サポート終了前に Blue/Green で 8.4 LTS へ」
  https://corporate.moobon.jp/blog/rds-mysql-80-to-84-blue-green-upgrade
- AWS Database Blog "Best practices for upgrading Amazon RDS for MySQL 8.0 to 8.4 with prechecks, Blue/Green, and rollback"
  https://aws.amazon.com/blogs/database/best-practices-for-upgrading-amazon-rds-for-mysql-8-0-to-8-4-with-prechecks-blue-green-and-rollback/
- AWS Database Blog "Upgrade strategies for Amazon RDS for MySQL 8.0 to 8.4"
  https://aws.amazon.com/blogs/database/upgrade-strategies-for-amazon-rds-for-mysql-8-0-to-8-4/
- Amazon RDS ユーザーガイド「MySQL feature support on Amazon RDS」
  https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html
- Amazon RDS ユーザーガイド「Configuring buffer pool size and redo log capacity in MySQL 8.4」
  https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.MySQL.CommonDBATasks.Config.Size.8.4.html
- MySQL 8.4 Reference Manual "What Is New in MySQL 8.4 since MySQL 8.0"
  https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html
