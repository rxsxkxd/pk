# タイムゾーン差異のレプリケーション検証（ローカル擬似環境）

[reference/mysql-timezone-replication-verification.md](../../reference/mysql-timezone-replication-verification.md) と同じ検証を、**AWS を使わずローカルの Docker だけで**行うための構成である。

ソースとレプリカで `time_zone` が異なる場合に、保存データが一致すること・表現とクエリ解釈だけが変わることを確認する。RDS 版と違い、課金もインスタンス作成待ちも発生しない。

```
source  （MySQL 8.4 / time_zone = UTC）      127.0.0.1:13306
   │
   └─ レプリケーション（GTID / ROW）
          │
          └─ replica （MySQL 8.4 / time_zone = Asia/Tokyo、read_only）  127.0.0.1:13307
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
