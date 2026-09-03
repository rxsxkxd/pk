# RDS の `time_zone` を `Asia/Tokyo` へ変更したときに起きること（要約）

## 結論

**`time_zone` は UTC のまま運用し、表示だけアプリケーション側で JST にするべきである。**

`Asia/Tokyo` へ変更すると、`DEFAULT CURRENT_TIMESTAMP` を持つ `datetime` 列に、**UTC の壁時計と JST の壁時計が混在する**。データ不整合として検知されないまま蓄積するため、発見が遅れる。

本書は判断材料としての要約である。網羅的な整理は [mysql-timezone.md](mysql-timezone.md)、実機での再現手順は [examples/mysql-timezone-replication/](../examples/mysql-timezone-replication/) にある。

## 対象となる構成

Rails で次のように定義した列が該当する。

```ruby
# t.timestamps が作るのは datetime 列（timestamp 列ではない）
change_column_default :users, :created_at, -> { "CURRENT_TIMESTAMP" }
```

### `t.timestamps` だけでは DB デフォルトは付かない

**`t.timestamps` が作るのは「DB デフォルトのない `datetime NOT NULL` 列」である。** 値は Rails が Ruby 側で入れる前提であり、`DEFAULT CURRENT_TIMESTAMP` は付かない。

DB デフォルトが付くのは、次のように**明示的に指定した場合だけ**である。

```ruby
# 1. マイグレーションで後から付けた場合
change_column_default :users, :created_at, -> { "CURRENT_TIMESTAMP" }

# 2. 作成時に default を渡した場合
t.timestamps default: -> { "CURRENT_TIMESTAMP" }

# 3. Rails 以外（生 DDL、他システムが作ったテーブル）で付いていた場合
```

したがって、**まず自分のスキーマに実際にデフォルトが付いているかを確認する**必要がある。確認方法は次のとおり。

```sql
-- DB の実態を見る（これが正）
SHOW CREATE TABLE users;
SELECT COLUMN_NAME, COLUMN_TYPE, COLUMN_DEFAULT, EXTRA
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users'
  AND COLUMN_NAME IN ('created_at', 'updated_at');
```

```sh
# schema.rb 側の表現
grep -n "CURRENT_TIMESTAMP" db/schema.rb
```

`COLUMN_DEFAULT` が `CURRENT_TIMESTAMP` なら該当する。`EXTRA` に `on update CURRENT_TIMESTAMP` があれば `updated_at` 側も該当する。

### schema.rb への出力はバージョンによらず可能

`datetime` 列の `DEFAULT CURRENT_TIMESTAMP` は、**Rails 5.2 でも 6.1 でも `default: -> { "CURRENT_TIMESTAMP" }` として schema.rb に出力される**。MySQL アダプタの `new_column_from_field` が `CURRENT_TIMESTAMP`（精度指定付きを含む）を関数デフォルトとして認識するためで、この処理は 5.2 の時点で入っている。

ただし **5.2 と 6.1 で扱える範囲が違う。**

| デフォルトの種類 | 5.2 | 6.1 |
|---|---|---|
| `DEFAULT CURRENT_TIMESTAMP`（`datetime` 列） | **認識する** | 認識する |
| MySQL 8.0.13+ の一般式デフォルト（`EXTRA` が `DEFAULT_GENERATED`。例: `DEFAULT (NOW() + INTERVAL 1 DAY)`） | **認識しない** | **認識する** |

5.2 で一般式デフォルトを使っている場合、schema.rb に出力されず `db:schema:load` で消える。本書の主題である `CURRENT_TIMESTAMP` は両方で扱えるため、この差は該当しない。

## 何が起きるか

`datetime` 型は**タイムゾーン変換を一切行わず、渡された壁時計をそのまま格納する**。ここが原因のすべてである。

| 挿入経路 | 変更前（`time_zone = UTC`） | 変更後（`time_zone = Asia/Tokyo`） |
|---|---|---|
| Rails 経由（`User.create!`） | UTC の壁時計 | **UTC の壁時計**（変わらない） |
| DB デフォルト（`CURRENT_TIMESTAMP`） | UTC の壁時計 | **JST の壁時計**（9 時間進む） |

変更前は両者が一致しているため問題が表面化しない。変更後は**同じ列に 9 時間ずれた 2 種類の値が混在する**。

Rails は `default_timezone`（既定 `:utc`）に従って**全行を UTC として読む**ため、DB デフォルトで入った行は「9 時間未来の作成日時」として解釈される。

## なぜ Rails 側の書き込みは変わらないのか

`ActiveRecord` は接続時にセッションの `time_zone` を設定しない。Rails 5.2 / 6.1 / 7 系のいずれでも、`abstract_mysql_adapter.rb` の `configure_connection` に `time_zone` の記述はない（`sql_mode`・`wait_timeout`・`database.yml` の `variables` は設定する）。

Ruby 側で UTC 文字列を組み立てて INSERT するため、**サーバーの `time_zone` を変えても Rails の書き込みは UTC のままである。** 変わるのは DB 側で値が生成される経路だけであり、それが混在を生む。

## DB デフォルトが実際に発火する経路

`User.create!` は Rails が `created_at` を明示的に送るため、DB デフォルトは使われない。発火するのは ActiveRecord のタイムスタンプ処理を迂回する経路である。

| 経路 | 補足 |
|---|---|
| **`insert_all` / `upsert_all`** | **Rails 5.2 / 6.1 では `created_at` を自動設定しない。**（詳細は後述） |
| 生 SQL の `INSERT` | 運用スクリプト、データ移行、管理ツール |
| 外部サービス・ETL からの書き込み | BI ツール、ワークフローエンジンなど |

`change_column_default` を入れる動機は通常これらの経路の保護だが、**`time_zone` を変更するとその保護が地雷に変わる。**

### `insert_all` / `upsert_all` のバージョン差

タイムスタンプの扱いは **Rails 7.0 で変わった。**

| | Rails 5.2 / 6.1 | Rails 7.0 以降 |
|---|---|---|
| `insert_all` が `created_at` / `updated_at` を設定するか | **しない** | **する**（`record_timestamps` が既定で有効） |
| `record_timestamps:` オプション | **ない** | ある（明示的に無効化も可能） |

そちらのバージョン（5.2 / 6.1）では **`insert_all` は `created_at` を送らない**。したがって、

- 列に `DEFAULT CURRENT_TIMESTAMP` が**ある** → サーバー側で値が生成される。**`time_zone` の影響を受ける**
- 列に `DEFAULT CURRENT_TIMESTAMP` が**ない** → `datetime NOT NULL` に値が入らず、**エラーまたはゼロ値**になる

つまり `insert_all` を使っているなら、そもそも DB デフォルトに依存している可能性が高い。ここが最も踏みやすい経路である。

### `upsert_all` は SQL に `CURRENT_TIMESTAMP` を直接埋める

**列にデフォルトが付いていなくても影響を受ける経路がある。** Rails 6.1 の `upsert_all`（`update_duplicates`）は、`ON DUPLICATE KEY UPDATE` 句を組み立てるときに `CURRENT_TIMESTAMP` を **SQL 文へ直接埋め込む**。

```sql
-- Rails 6.1 が生成する SQL（抜粋）
ON DUPLICATE KEY UPDATE
  updated_at=(CASE WHEN (...) THEN users.updated_at ELSE CURRENT_TIMESTAMP END), ...
```

この `CURRENT_TIMESTAMP` はサーバー側でセッションの `time_zone` に従って評価される。したがって、

- `updated_at` が `datetime` 列である限り、**`time_zone` を変更すると衝突時に JST の壁時計が書き込まれる**
- 列に `DEFAULT` や `ON UPDATE` を付けていなくても発生する
- 新規挿入行は Ruby 側の UTC 値、衝突更新行は JST 値となり、**同じ列に混在する**

`upsert_all` を使っている場合、`change_column_default` の有無に関わらず影響を受ける点に注意する。

## 影響範囲

- **既存行は書き換わらない。** 影響は変更後の新規挿入だけである。結果として「変更前の行は整合、変更後の行は経路依存」という、時系列で分断された状態になる
- `updated_at` に `ON UPDATE CURRENT_TIMESTAMP` を付けている場合は、**UPDATE のたびに**同じことが起きる
- 列が `timestamp` 型であればこの問題は起きない（内部 UTC 保存のため、どのセッションから INSERT しても同じ絶対時刻になる）

## `CURRENT_TIMESTAMP` 以外に同時に起きること

`time_zone` の変更は、この列の問題だけでは終わらない。次も同時に発生する。

| 変わるもの | 内容 |
|---|---|
| 日時リテラルの解釈 | `WHERE ts >= '2026-09-03 00:00:00'` の意味が 9 時間ずれ、**返る行が変わる** |
| 日付の切り出し | `GROUP BY DATE(ts)` の日境界がずれ、**日次集計の結果が変わる** |
| `TIMESTAMP` 列の表示 | 読み出し値が 9 時間ずれる（保存値は変わらない） |
| `NOW()` 系 | `NOW()`、`CURDATE()`、`FROM_UNIXTIME()` がすべて JST 基準になる |

いずれも `timestamp` 列か `datetime` 列かに関わらず、**サーバー側で評価される箇所すべて**に及ぶ。

## 推奨

**DB は UTC のまま維持する。** 表示のタイムゾーンはアプリケーション側で完結できる（Rails なら `config.time_zone`）ため、DB のタイムゾーンを動かす必要はない。

どうしても `Asia/Tokyo` にする場合は、事前に次を実施する。

1. **`DEFAULT CURRENT_TIMESTAMP` / `ON UPDATE CURRENT_TIMESTAMP` を持つ列の棚卸し。** `schema.rb` の grep だけでなく、`information_schema.COLUMNS` で DB の実態を確認する（前掲のクエリ）
2. **該当列の型の確認。** `datetime` なら混在が起きる。`timestamp` なら起きない
3. **`insert_all` / `upsert_all` の使用箇所の洗い出し。** 5.2 / 6.1 ではタイムスタンプを自動設定しないため、DB デフォルトに依存している可能性が高い。`upsert_all` は列のデフォルトに関わらず SQL へ `CURRENT_TIMESTAMP` を埋めるため、単独で影響を受ける
4. **生 SQL・外部ツールによる挿入経路の洗い出し**
5. **日時リテラルを含む `WHERE` 句と、`GROUP BY DATE()` を使う集計の洗い出し**

```sh
grep -rn "insert_all\|upsert_all" app/ lib/
grep -rn "CURRENT_TIMESTAMP" db/schema.rb db/structure.sql
```

## 関連ドキュメント

- [mysql-timezone.md](mysql-timezone.md) — タイムゾーン関連パラメータと影響範囲の網羅的な整理
- [mysql-timezone-replication-verification.md](mysql-timezone-replication-verification.md) — AWS 上での検証手順
- [examples/mysql-timezone-replication/](../examples/mysql-timezone-replication/) — ローカル Docker での再現環境（`DEFAULT CURRENT_TIMESTAMP` の混在検証を含む）
