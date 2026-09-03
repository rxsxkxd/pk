# タイムゾーン差異のレプリケーション検証（ローカル擬似環境）

[reference/mysql-timezone-replication-verification.md](../../reference/mysql-timezone-replication-verification.md) と同じ検証を、**AWS を使わずローカルの Docker だけで**行うための構成である。

ソースとレプリカで `time_zone` が異なる場合に、保存データが一致すること・表現とクエリ解釈だけが変わることを確認する。RDS 版と違い、課金もインスタンス作成待ちも発生しない。

バージョンは本プロジェクトの移行構成に合わせ、**ソースを MySQL 8.0（Blue 相当）、レプリカを MySQL 8.4（Green 相当）**としている。8.0 → 8.4 のレプリケーションは Blue/Green Deployment が内部で行っているものと同じ関係である。

```
source  （MySQL 8.0.46 / time_zone = UTC）                        127.0.0.1:13306
   │      ＝ 移行元 Blue 相当
   │
   └─ レプリケーション（GTID / ROW）
          │
          └─ replica （MySQL 8.4.8 / time_zone = Asia/Tokyo、read_only）  127.0.0.1:13307
                 ＝ 移行先 Green 相当
```

## RDS 版との違い

ローカルの素の MySQL は RDS と既定値が異なるため、RDS に寄せる設定を明示的に入れてある。**この差自体が RDS の仕様を理解する材料になる。**

| 項目 | 素の MySQL | RDS | 本環境での扱い |
|---|---|---|---|
| `time_zone` の既定値 | `SYSTEM` | `UTC` | `conf/source.cnf` で `+00:00`（UTC と等価）を明示 |
| `mysql.time_zone_*` テーブル | **空**。名前付きタイムゾーンを使えない | AWS が事前ロード済み | `setup.sh` が `mysql_tzinfo_to_sql` でロード |
| レプリカの `read_only` | 既定 OFF | リードレプリカは強制 ON | `conf/replica.cnf` で `read_only = ON` |
| 設定の変更単位 | 設定ファイル / `SET PERSIST` | DB パラメータグループ | 設定ファイルと `SET PERSIST` |
| レプリケーション構成 | 手動で `CHANGE REPLICATION SOURCE TO` | `create-db-instance-read-replica` の 1 コマンド | `setup.sh` が実行 |

> 起動時に `time_zone` へ名前付きタイムゾーン（`Asia/Tokyo` など）を指定すると、`mysql.time_zone_*` が未ロードのため **MySQL が起動に失敗する**。このため両方とも起動時はオフセット指定にし、テーブルをロードしてからレプリカを `Asia/Tokyo` へ切り替えている。

### バージョン差に由来する注意

ソース（8.0）とレプリカ（8.4）でバージョンが違うため、次の点が非対称になる。

| 項目 | ソース（8.0.46） | レプリカ（8.4.8） |
|---|---|---|
| `--mysql-native-password` オプション | **存在しない**。渡すと起動に失敗する | 8.4 で追加された。既定で `OFF` |
| 既定の認証プラグイン | `caching_sha2_password` | `caching_sha2_password`（`mysql_native_password` は既定で無効） |
| `binlog_format` | 通常のパラメータ | **非推奨**（値は設定できる） |
| `SHOW SLAVE STATUS` / `CHANGE MASTER TO` | 使える（非推奨） | **削除済み**。`SHOW REPLICA STATUS` / `CHANGE REPLICATION SOURCE TO` を使う |

`setup.sh` はレプリカ（8.4）側で新構文のみを使い、TLS なしで `caching_sha2_password` の認証を通すため `GET_SOURCE_PUBLIC_KEY=1` を指定している。

## 起動

```sh
cd examples/mysql-timezone-replication
cp .env.example .env
docker compose up -d
./setup.sh
```

`setup.sh` は次を行う。冪等なので再実行できる。

1. `mysql.time_zone_*` を両方にロードする
2. レプリカの `time_zone` を `SET PERSIST` で `Asia/Tokyo` にする（再起動後も維持される）
3. レプリケーションユーザーを作成し、GTID ベースでレプリケーションを開始する
4. レプリケーションが `ON / ON` になるまで待って確認する

## 検証手順

検証内容は RDS 版と同一である。[reference/mysql-timezone-replication-verification.md](../../reference/mysql-timezone-replication-verification.md) の**手順 2 以降**をそのまま実施できる（手順 1 の構成作成は `docker compose up -d` と `setup.sh` が代替する）。

### SQL での検証（手順 2〜5）

`client` サービスから接続する。

```sh
# ソースへ接続する
docker compose run --rm client mysql -h source -uroot tzcheck

# レプリカへ接続する
docker compose run --rm client mysql -h replica -uroot tzcheck
```

`MYSQL_PWD` は compose の環境変数から渡されるため、パスワードの入力は不要である。

まず設定を確認する（RDS 版の手順 2 に相当）。

```sql
SELECT @@global.time_zone, @@session.time_zone, @@system_time_zone;
```

| 接続先 | `global` | `session` | `system` |
|---|---|---|---|
| `source` | `+00:00` | `+00:00` | `UTC` |
| `replica` | `Asia/Tokyo` | `Asia/Tokyo` | `UTC` |

> RDS では `global` が `UTC` と表示されるが、本環境では `+00:00` になる。値としては等価であり、以降の検証結果は変わらない。

以降、RDS 版の手順 3（データ投入）、手順 4（保存データの一致）、手順 5（表現とクエリ解釈の差）をそのまま実行する。

### ドライバでの検証（手順 6）

ホストから `127.0.0.1` の公開ポートへ接続する。RDS 版の手順 6 のコードをそのまま使い、接続先だけ差し替える。

```sh
export SOURCE_HOST=127.0.0.1
export REPLICA_HOST=127.0.0.1
export MYSQL_PWD=<.env に設定した値>
```

ポートが標準と異なるため、各コードの接続先を次のように読み替える。

| 言語 | 読み替え |
|---|---|
| Go | `tcp(%s:3306)` → `tcp(127.0.0.1:13306)` / `tcp(127.0.0.1:13307)` |
| Ruby | `host:` に加えて `port: 13306` / `port: 13307` を渡す |
| Python | `pymysql.connect(..., port=13306)` / `port=13307` |

ユーザーは `root`、データベースは `tzcheck` である。

## `DEFAULT CURRENT_TIMESTAMP` の混在検証

[reference/mysql-timezone.md](../../reference/mysql-timezone.md) の「6. スキーマ定義に埋め込まれるもの」で述べた、**`TIMESTAMP` 列は安全で `DATETIME` 列は危険**という違いを実証する。

**この検証に Rails は不要である。** 危険の本体は MySQL サーバー側の挙動であり、素の SQL で完全に再現できる。Rails 側の確認項目（`ActiveRecord::Base.default_timezone` が `:utc` であること等）は既存アプリの `rails console` で別途確認する。

レプリケーションとも無関係なので、**ソース 1 台だけ**で実施できる。

```sh
docker compose run --rm client mysql -h source -uroot tzcheck
```

### 1. 両方の型を持つテーブルを作る

```sql
CREATE TABLE ct (
  id  INT PRIMARY KEY AUTO_INCREMENT,
  ts  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,   -- 内部 UTC 保存。安全側
  dt  DATETIME  DEFAULT CURRENT_TIMESTAMP,   -- 壁時計をそのまま保存。危険側
  who VARCHAR(16)
);
```

### 2. 異なるセッションタイムゾーンから、DB のデフォルト任せで INSERT する

同一接続内でセッションを切り替えれば再現できる（別々の接続でも同じ結果になる）。

```sql
SET time_zone = '+00:00';
INSERT INTO ct (who) VALUES ('utc-session');

SET time_zone = 'Asia/Tokyo';
INSERT INTO ct (who) VALUES ('jst-session');
```

### 3. 比較する

セッションを UTC に固定して読み出す。**読み出し条件を揃えることで、保存値そのものの差が見える。**

```sql
SET time_zone = '+00:00';
SELECT id, who, ts, dt, UNIX_TIMESTAMP(ts) AS ts_epoch FROM ct ORDER BY id;
```

期待する結果。

| who | `ts`（UTC で読み出し） | `dt` | 判定 |
|---|---|---|---|
| `utc-session` | 投入時刻（UTC） | 投入時刻（UTC の壁時計） | — |
| `jst-session` | **同じ絶対時刻**（`ts_epoch` が連続する） | **9 時間進んだ値**（JST の壁時計がそのまま入っている） | **混在** |

- **`ts`（`TIMESTAMP`）**: 2 行の `ts_epoch` は INSERT した実時刻どおりの差（数秒）になる。セッションのタイムゾーンが違っても、**同じ絶対時刻として保存されている**
- **`dt`（`DATETIME`）**: 2 行目だけ 9 時間進んだ値が入る。**同じ列に UTC の壁時計と JST の壁時計が混在した**

この状態のまま、アプリケーションが `dt` を一律 UTC とみなして読むと、2 行目は 9 時間ずれた時刻として解釈される。**データ不整合として検知されないため、発見が遅れる。**

### 4. 対処の確認（任意）

`dt` 列を `TIMESTAMP` へ変えると混在しなくなることを確認できる。

```sql
CREATE TABLE ct2 (
  id INT PRIMARY KEY AUTO_INCREMENT,
  dt TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  who VARCHAR(16)
);

SET time_zone = '+00:00';
INSERT INTO ct2 (who) VALUES ('utc-session');
SET time_zone = 'Asia/Tokyo';
INSERT INTO ct2 (who) VALUES ('jst-session');

SET time_zone = '+00:00';
SELECT id, who, dt, UNIX_TIMESTAMP(dt) AS epoch FROM ct2 ORDER BY id;
```

2 行の `epoch` が INSERT の実時刻どおりの差になり、9 時間のずれが発生しないことを確認する。

### Rails を使う場合の補足

`t.timestamps` が作るのは **`datetime` 列**であり、上記の危険側に該当する。ただし Rails は既定でセッションの `time_zone` を設定せず、`default_timezone`（既定 `:utc`）に従って Ruby 側で UTC 文字列を組み立てて INSERT するため、**Rails 経由の書き込みだけであれば混在しない**。

混在が起きるのは、同じ列に対して **DB 側のデフォルト（`DEFAULT CURRENT_TIMESTAMP`）で値が入る経路が併存する場合**である。手順 2 の `jst-session` がその経路に相当する。

Rails 側の確認は既存アプリの `rails console` で行う。API 名がバージョンで変わる点に注意する。

```ruby
# Rails 5.2 / 6.1
ActiveRecord::Base.default_timezone                            # => :utc
# Rails 7.0 以降は ActiveRecord.default_timezone

ActiveRecord::Base.connection.select_value("SELECT @@session.time_zone")
```

## 停止と後始末

```sh
# 停止（データは残る。再開は docker compose up -d）
docker compose stop

# 完全に削除する（ボリュームも消す）
docker compose down -v
```

RDS 版と違い課金は発生しないが、named volume にデータが残るため、検証が終わったら `down -v` で消しておく。

## 注意

- **使い捨ての検証環境である。実データを入れない。**
- ポートは `127.0.0.1` にのみ公開しており、外部からは接続できない。
- `.env` はリポジトリルートの `.gitignore` で除外される。`.env.example` の値は使い捨てのローカル専用であり、実環境の認証情報を書かない。
- リポジトリルートの `compose.yaml`（AWS CLI・MySQL クライアント等の実行用）とは独立している。Compose のプロジェクト名も `mysql-timezone-replication` と分けてあるため、同時に起動しても衝突しない。
