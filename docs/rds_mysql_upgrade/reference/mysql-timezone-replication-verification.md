# タイムゾーン差異のレプリケーション検証手順

## 目的

[mysql-timezone.md](mysql-timezone.md) の「レプリケーション構成でソースとレプリカの `time_zone` が異なる場合」で述べた内容を、実際の AWS 環境で検証する。検証する仮説は次の 2 つである。

| # | 仮説 | 期待する結果 |
|---|---|---|
| 1 | ソースとレプリカで `time_zone` が異なっても、**保存されるデータは一致する** | 内部表現（UNIX 時刻）が両者で完全に一致する |
| 2 | 差が出るのは**クライアントから見える表現とクエリの解釈だけ**である | 表示値・`WHERE` 句の該当行・`GROUP BY DATE()` の集計結果が変わる |

> **AWS を使わずに同じ検証を行う場合**は、ローカルの Docker で擬似環境を作る [examples/mysql-timezone-replication/](../examples/mysql-timezone-replication/) を使う。課金もインスタンス作成待ちも発生せず、手順 2 以降は本書をそのまま流用できる。RDS 固有の挙動（パラメータグループ、スナップショット復元時の扱いなど）を確認したい場合は本書の AWS 構成で実施する。

## 前提と注意

> **本番環境では実施しない。** 本手順は使い捨ての検証用インスタンスを新規作成する。既存のインスタンスやパラメータグループには一切変更を加えない。

> **課金が発生する。** DB インスタンス 2 台（ソース＋リードレプリカ）とストレージが課金対象になる。検証後は「6. 後始末」を必ず実施する。`db.t4g.micro` を使い、検証は 1 時間以内に完了する想定である。

### ソース側は「利用者未設定」とする

ソース側は、**パラメータグループで `time_zone` を設定しない**（RDS の `Source=user` に `time_zone` を持たせない）構成とする。エンジン既定値がそのまま効く状態である。

RDS における `time_zone` の**エンジン既定値は `UTC`** であり、`SYSTEM` ではない。また `SYSTEM` は [AWS がサポート値として列挙している一覧](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.LocalTimeZone.html)に含まれていないため、RDS のパラメータグループで意図的に `SYSTEM` を選ぶことはできない。仮に設定できたとしても、RDS のホストのタイムゾーンは UTC のため解決結果は `UTC` となり、観測される挙動は同じになる。

実際に `@@global.time_zone` が何を返すかは検証手順 2 で実測する。

## 構成

```
tz-test-source   （MySQL 8.4 / パラメータグループ: time_zone は利用者未設定 → エンジン既定の UTC）
      │
      └─ レプリケーション
             │
             └─ tz-test-replica （MySQL 8.4 / パラメータグループ: time_zone = Asia/Tokyo）
```

パラメータグループはソースとレプリカで**別のものを割り当てる**。同一のパラメータグループを共有すると、変更が両方に適用されてしまい検証にならない。

## 1. 構成の作成

以下は `aws` CLI での例である。`<...>` の箇所は環境に合わせて置き換える。ネットワーク（サブネットグループ・セキュリティグループ）は既存のものを使い、**MySQL クライアントから到達できる構成**にする。

### 1-1. パラメータグループを 2 つ作成する

```sh
# ソース用（time_zone は設定しない。エンジン既定のままにする）
aws rds create-db-parameter-group \
  --db-parameter-group-name tz-test-source-mysql84 \
  --db-parameter-group-family mysql8.4 \
  --description "timezone verification: source (time_zone unset)"

# レプリカ用
aws rds create-db-parameter-group \
  --db-parameter-group-name tz-test-replica-mysql84 \
  --db-parameter-group-family mysql8.4 \
  --description "timezone verification: replica (Asia/Tokyo)"

# レプリカ用にだけ time_zone を設定する
aws rds modify-db-parameter-group \
  --db-parameter-group-name tz-test-replica-mysql84 \
  --parameters "ParameterName=time_zone,ParameterValue=Asia/Tokyo,ApplyMethod=immediate"
```

両方のパラメータグループについて、`Source=user`（利用者が明示設定した値）の内容を確認する。

```sh
# レプリカ用: time_zone = Asia/Tokyo が 1 件だけ返ること
aws rds describe-db-parameters \
  --db-parameter-group-name tz-test-replica-mysql84 \
  --source user \
  --query 'Parameters[].[ParameterName,ParameterValue,ApplyType]' \
  --output table

# ソース用: 何も返らない（time_zone を利用者設定として持たない）ことを確認する
aws rds describe-db-parameters \
  --db-parameter-group-name tz-test-source-mysql84 \
  --source user \
  --query 'Parameters[].[ParameterName,ParameterValue]' \
  --output text
```

あわせて、ソース側で実際に効くエンジン既定値を確認しておく。

```sh
aws rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.4 \
  --query 'EngineDefaults.Parameters[?ParameterName==`time_zone`].[ParameterName,ParameterValue,IsModifiable,ApplyType]' \
  --output table
```

### 1-2. ソース DB インスタンスを作成する

リードレプリカを作成するには、ソースの自動バックアップが有効（`--backup-retention-period` が 1 以上）である必要がある。

```sh
aws rds create-db-instance \
  --db-instance-identifier tz-test-source \
  --db-instance-class db.t4g.micro \
  --engine mysql \
  --engine-version 8.4.10 \
  --allocated-storage 20 \
  --master-username admin \
  --manage-master-user-password \
  --backup-retention-period 1 \
  --db-parameter-group-name tz-test-source-mysql84 \
  --no-multi-az \
  --db-subnet-group-name <subnet-group> \
  --vpc-security-group-ids <sg-id>

aws rds wait db-instance-available --db-instance-identifier tz-test-source
```

`--manage-master-user-password` を使い、パスワードをコマンドラインに書かず Secrets Manager に管理させる。

### 1-3. リードレプリカを作成する

作成時に**レプリカ用のパラメータグループを明示指定する**。

```sh
aws rds create-db-instance-read-replica \
  --db-instance-identifier tz-test-replica \
  --source-db-instance-identifier tz-test-source \
  --db-instance-class db.t4g.micro \
  --db-parameter-group-name tz-test-replica-mysql84

aws rds wait db-instance-available --db-instance-identifier tz-test-replica
```

### 1-4. 接続情報を取得する

```sh
# エンドポイント
aws rds describe-db-instances --db-instance-identifier tz-test-source \
  --query 'DBInstances[0].Endpoint.Address' --output text
aws rds describe-db-instances --db-instance-identifier tz-test-replica \
  --query 'DBInstances[0].Endpoint.Address' --output text

# パスワード（Secrets Manager から取得する。レプリカはソースと同じ認証情報を使う）
secret_arn=$(aws rds describe-db-instances --db-instance-identifier tz-test-source \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)
aws secretsmanager get-secret-value --secret-id "$secret_arn" \
  --query SecretString --output text
```

接続には本リポジトリの MySQL コンテナを使える（[local-execution.md](../local-execution.md)）。

```sh
docker compose --env-file .env run --rm mysql \
  mysql --host=<endpoint> --user=admin -p
```

## 2. 設定値の確認（仮説の前提確認）

**ソースとレプリカの両方**で実行する。

```sql
SELECT @@global.time_zone   AS global_tz,
       @@session.time_zone  AS session_tz,
       @@system_time_zone   AS system_tz;
```

期待する結果。

| 接続先 | `time_zone` の設定状態 | `global_tz` | `session_tz` | `system_tz` |
|---|---|---|---|---|
| ソース | 利用者未設定（エンジン既定） | `UTC` | `UTC` | `UTC` |
| レプリカ | `Source=user` で `Asia/Tokyo` | `Asia/Tokyo` | `Asia/Tokyo` | `UTC` |

> ソースの `global_tz` が `SYSTEM` と表示された場合は、本書冒頭の前提（エンジン既定は `UTC`）がその環境・エンジンバージョンでは異なることを意味する。その場合は実測値をそのまま記録する。`system_tz` が `UTC` である限り `SYSTEM` の解決結果も `UTC` になるため、以降の検証結果は変わらない。

## 3. 検証用データの投入（ソースでのみ実行）

日付境界をまたぐ値を意図的に含める。

```sql
CREATE DATABASE tzcheck;

CREATE TABLE tzcheck.t (
  id   INT PRIMARY KEY,
  ts   TIMESTAMP NOT NULL,   -- UTC で保存され、読み出し時に変換される
  dt   DATETIME  NOT NULL,   -- 変換されない
  note VARCHAR(32)
);

-- セッションのタイムゾーンを明示してから投入する（ソースは UTC）
SET time_zone = '+00:00';

INSERT INTO tzcheck.t (id, ts, dt, note) VALUES
  (1, '2026-09-02 20:00:00', '2026-09-02 20:00:00', 'boundary'),
  (2, '2026-09-03 05:00:00', '2026-09-03 05:00:00', 'same-day');
```

`id=1` は UTC では 9/2 だが JST では 9/3 になる（日付境界をまたぐ）値である。

レプリカに反映されるまで待つ。

```sql
-- レプリカで実行し、2 行返ることを確認する
SELECT COUNT(*) FROM tzcheck.t;
```

## 4. 仮説 1 の検証: 保存されたデータが一致すること

### 4-1. 内部表現を直接比較する

`UNIX_TIMESTAMP()` は、**引数が `TIMESTAMP` 列の場合、内部表現をそのまま返す**（文字列変換を経由しない）。このためセッションのタイムゾーンに影響されず、保存値そのものを比較できる。

**ソースとレプリカの両方**で実行する。

```sql
SELECT id,
       UNIX_TIMESTAMP(ts) AS ts_internal,
       dt,
       note
FROM tzcheck.t
ORDER BY id;
```

**判定: `ts_internal` と `dt` が両者で完全に一致すれば、仮説 1 は成立する。**

### 4-2. セッションを UTC に揃えて比較する（補強）

別の角度からも確認する。レプリカのセッションを UTC に変更すると、ソースと同じ表示になるはずである。

```sql
-- レプリカで実行する
SET time_zone = '+00:00';
SELECT id, ts, dt FROM tzcheck.t ORDER BY id;
```

**判定: ソースでの結果（手順 3 の投入値）と完全に一致すれば、差異がセッション表現だけであることが確認できる。**

確認後、レプリカのセッションを元に戻す。

```sql
SET time_zone = @@global.time_zone;
```

## 5. 仮説 2 の検証: 表現とクエリ解釈だけが変わること

以降は**セッションのタイムゾーンを変更せず**（レプリカは `Asia/Tokyo` のまま）実行する。

### 5-1. 表示値の差（`TIMESTAMP` はずれ、`DATETIME` はずれない）

```sql
SELECT id, ts, dt, note FROM tzcheck.t ORDER BY id;
```

| id | 列 | ソース（UTC） | レプリカ（JST） |
|---|---|---|---|
| 1 | `ts` | `2026-09-02 20:00:00` | **`2026-09-03 05:00:00`**（+9 時間） |
| 1 | `dt` | `2026-09-02 20:00:00` | `2026-09-02 20:00:00`（**同じ**） |
| 2 | `ts` | `2026-09-03 05:00:00` | **`2026-09-03 14:00:00`**（+9 時間） |
| 2 | `dt` | `2026-09-03 05:00:00` | `2026-09-03 05:00:00`（**同じ**） |

同じ行の中で `ts` だけがずれ、`dt` はずれないことを確認する。

### 5-2. `WHERE` 句のリテラル解釈の差

```sql
SELECT COUNT(*) AS matched FROM tzcheck.t WHERE ts >= '2026-09-03 00:00:00';
```

| 接続先 | リテラルの意味 | 結果 |
|---|---|---|
| ソース（UTC） | `2026-09-03 00:00:00 UTC` | **1**（`id=2` のみ該当） |
| レプリカ（JST） | `2026-09-03 00:00:00 JST` = `2026-09-02 15:00:00 UTC` | **2**（`id=1`、`id=2` とも該当） |

**同じデータに対する同じクエリが、異なる行数を返す**ことを確認する。

### 5-3. `GROUP BY DATE()` の集計結果の差

```sql
SELECT DATE(ts) AS d, COUNT(*) AS cnt FROM tzcheck.t GROUP BY DATE(ts) ORDER BY d;
```

| 接続先 | 結果 |
|---|---|
| ソース（UTC） | `2026-09-02` → 1 件、`2026-09-03` → 1 件（**2 グループ**） |
| レプリカ（JST） | `2026-09-03` → 2 件（**1 グループ**） |

日付境界がずれることで、**集計のグループ数そのものが変わる**ことを確認する。

### 5-4. 対照実験（任意）

差異がレプリケーションではなくセッション設定に由来することを確認する。**ソースだけ**で次を実行する。

```sql
SET time_zone = 'Asia/Tokyo';
SELECT id, ts, dt FROM tzcheck.t ORDER BY id;
SET time_zone = @@global.time_zone;
```

レプリカ（JST）と同じ表示になれば、差異はレプリケーションとは無関係にセッション設定だけで再現できることが分かる。

## 6. アプリケーションドライバ経由での検証（Go / Ruby / Python）

手順 4・5 は `mysql` クライアントでの検証である。しかし実際のアプリケーションは各言語のドライバ経由で接続し、**ドライバはサーバーのセッション `time_zone` とは別に、自分自身のタイムゾーン層を持つ**。ここが一致していないと、サーバー側が正しくてもアプリケーションが受け取る時刻がずれる。

### 共通の判定基準

3 言語とも、確認するのは次の 1 点である。

> **ドライバが解釈した時刻を UNIX 時刻に直した値が、サーバーが返す `UNIX_TIMESTAMP(ts)` と一致すること。**

`UNIX_TIMESTAMP(ts)` は `TIMESTAMP` 列に対して内部表現をそのまま返すため（手順 4-1 参照）、セッションのタイムゾーンに依存しない絶対値である。これとドライバ側の解釈が一致すれば、**ドライバがタイムゾーン差を正しく吸収できている**ことになる。

ソースとレプリカの両方でこの一致が成り立てば、「接続先の `time_zone` が違っても、アプリケーションが受け取る絶対時刻は変わらない」ことが確認できる。

事前に接続情報を環境変数へ入れておく。

```sh
export SOURCE_HOST=<source-endpoint>
export REPLICA_HOST=<replica-endpoint>
export MYSQL_PWD=<password>   # Secrets Manager から取得した値
```

### 6-1. Go（go-sql-driver/mysql）

Go では DSN の `loc` が「サーバーから返る日時文字列をどのロケーションとして解釈するか」を決める。**既定は `UTC`** であり、`loc` はサーバーの `time_zone` を変更しない（両者は独立している）。

```go
package main

import (
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

func probe(label, host, loc string) {
	dsn := fmt.Sprintf("admin:%s@tcp(%s:3306)/tzcheck?parseTime=true&loc=%s",
		os.Getenv("MYSQL_PWD"), host, loc)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		panic(err)
	}
	defer db.Close()

	var sessionTZ string
	if err := db.QueryRow("SELECT @@session.time_zone").Scan(&sessionTZ); err != nil {
		panic(err)
	}
	fmt.Printf("[%s] loc=%s session_time_zone=%s\n", label, loc, sessionTZ)

	rows, err := db.Query("SELECT id, ts, UNIX_TIMESTAMP(ts) FROM t ORDER BY id")
	if err != nil {
		panic(err)
	}
	defer rows.Close()

	for rows.Next() {
		var id int
		var ts time.Time
		var serverEpoch int64
		if err := rows.Scan(&id, &ts, &serverEpoch); err != nil {
			panic(err)
		}
		fmt.Printf("  id=%d driver=%s driver_unix=%d server_unix=%d match=%v\n",
			id, ts.Format("2006-01-02 15:04:05 -0700"),
			ts.Unix(), serverEpoch, ts.Unix() == serverEpoch)
	}
	if err := rows.Err(); err != nil {
		panic(err)
	}
}

func main() {
	// loc をそれぞれの接続先のセッション time_zone に合わせる。
	probe("source", os.Getenv("SOURCE_HOST"), "UTC")
	probe("replica", os.Getenv("REPLICA_HOST"), "Asia%2FTokyo")
}
```

実行例。

```sh
mkdir -p /tmp/tzcheck-go && cd /tmp/tzcheck-go
go mod init tzcheck
go get github.com/go-sql-driver/mysql
# 上記のコードを main.go として保存してから実行する
go run .
```

**確認したいこと: どちらも `match=true` になること。** `loc` をサーバーのセッション `time_zone` に合わせれば、接続先が違ってもドライバは同じ絶対時刻を返す。

対比として、レプリカに `loc=UTC`（既定値のまま）で接続すると `match=false` になる。サーバーが JST に変換した文字列を、ドライバが UTC として解釈するため 9 時間ずれる。これは `loc` を明示していないアプリケーションで実際に起きる不具合である。

`loc` を合わせる代わりに、DSN でサーバーのセッションを固定する方法もある。この場合は接続先によらず `loc=UTC` で揃う。

```
?parseTime=true&loc=UTC&time_zone=%27%2B00%3A00%27
```

実行環境は本リポジトリの Go コンテナを使えるが、`go-sql-driver/mysql` の依存追加が必要になる。検証用の一時ディレクトリで `go mod init` してから実行するのが簡単である。

### 6-2. Ruby（mysql2）

mysql2 には 2 つのオプションがある。`database_timezone` は「データベース側の値がどのタイムゾーンで保存されていると仮定するか」、`application_timezone` は「呼び出し元へ返す前にどこへ変換するか」である。既定値はドキュメントに明示されていないため、**常に明示指定する**。

```ruby
require 'mysql2'

def probe(label, host, database_timezone:)
  client = Mysql2::Client.new(
    host: host, username: 'admin', password: ENV.fetch('MYSQL_PWD'),
    database: 'tzcheck',
    database_timezone: database_timezone,
    application_timezone: :utc
  )
  session_tz = client.query('SELECT @@session.time_zone AS tz').first['tz']
  puts "[#{label}] database_timezone=#{database_timezone} session_time_zone=#{session_tz}"

  client.query('SELECT id, ts, UNIX_TIMESTAMP(ts) AS server_epoch FROM t ORDER BY id').each do |row|
    driver_epoch = row['ts'].to_i
    match = driver_epoch == row['server_epoch']
    puts "  id=#{row['id']} driver=#{row['ts']} driver_unix=#{driver_epoch} " \
         "server_unix=#{row['server_epoch']} match=#{match}"
  end
ensure
  client&.close
end

probe('source',  ENV.fetch('SOURCE_HOST'),  database_timezone: :utc)
probe('replica', ENV.fetch('REPLICA_HOST'), database_timezone: :local)
```

**確認したいこと: どちらも `match=true` になること。**

レプリカ側は `database_timezone: :local` としているため、**Ruby プロセスの `TZ` が `Asia/Tokyo` である必要がある**（`TZ=Asia/Tokyo ruby probe.rb`）。プロセスのタイムゾーンとサーバーのセッション `time_zone` が食い違うと `match=false` になる。mysql2 は `database_timezone` に `:utc` か `:local` しか受け付けないため、**サーバー側が UTC 以外のときは、プロセスの `TZ` を合わせるか、接続直後に `SET time_zone='+00:00'` してサーバー側を UTC に寄せるのが確実**である。

なお `mysql2` gem はネイティブ拡張のため、`ruby:3.4.10` コンテナで使うには MySQL クライアントライブラリの開発パッケージが必要になる。

### 6-3. Python（PyMySQL）

PyMySQL は `DATETIME` / `TIMESTAMP` を **naive な `datetime.datetime`（`tzinfo` が `None`）** として返す。ドライバ側のタイムゾーン変換機構を持たないため、**吸収は行われない**。

```python
#!/usr/bin/env python3
import os
import pymysql

def probe(label, host):
    conn = pymysql.connect(
        host=host, user="admin", password=os.environ["MYSQL_PWD"],
        database="tzcheck", charset="utf8mb4",
    )
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT @@session.time_zone")
            print(f"[{label}] session_time_zone={cur.fetchone()[0]}")
            cur.execute("SELECT id, ts, UNIX_TIMESTAMP(ts) FROM t ORDER BY id")
            for id_, ts, server_epoch in cur.fetchall():
                print(f"  id={id_} driver={ts} tzinfo={ts.tzinfo} server_unix={server_epoch}")
    finally:
        conn.close()

probe("source", os.environ["SOURCE_HOST"])
probe("replica", os.environ["REPLICA_HOST"])
```

```sh
python3 -m venv /tmp/tzcheck-venv
/tmp/tzcheck-venv/bin/pip install PyMySQL
/tmp/tzcheck-venv/bin/python3 probe.py
```

**確認したいこと。**

- `server_unix` がソースとレプリカで**一致する**こと（データが同一であることの再確認）
- `tzinfo` が両方とも `None` であること
- `driver` の表示がソースとレプリカで 9 時間ずれること

Python では**ドライバが差を吸収しない**ため、アプリケーション側でタイムゾーンを付与する必要がある。naive な `datetime` に対して `.timestamp()` を呼ぶと**プロセスのローカルタイムゾーン**で解釈されるため、サーバーのセッション `time_zone` と食い違うと誤った絶対時刻になる。接続直後に `SET time_zone='+00:00'` を実行して UTC に固定し、`datetime.replace(tzinfo=timezone.utc)` を明示するのが安全である。

### 6-4. ドライバでは吸収できないことの確認（`WHERE` / `GROUP BY`）

手順 6-1〜6-3 で確認したのは**読み取りパス**、すなわち「サーバーが返した値をドライバがどう解釈するか」である。ここはドライバ設定で吸収できる。

一方、手順 5-2・5-3 で見た `WHERE` 句のリテラル解釈と `GROUP BY DATE()` の集計は、**サーバー側で行が確定した後にドライバへ渡る**。ドライバが受け取る時点で既に行数もグループ数も違っており、**ドライバ設定では原理的に吸収できない**。ここを確認する。

`loc` を変えても結果が変わらないことを示す。

```go
func probeServerSide(label, host, loc string) {
	dsn := fmt.Sprintf("admin:%s@tcp(%s:3306)/tzcheck?parseTime=true&loc=%s",
		os.Getenv("MYSQL_PWD"), host, loc)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		panic(err)
	}
	defer db.Close()

	var matched int
	if err := db.QueryRow(
		"SELECT COUNT(*) FROM t WHERE ts >= '2026-09-03 00:00:00'").Scan(&matched); err != nil {
		panic(err)
	}

	var groups int
	if err := db.QueryRow(
		"SELECT COUNT(*) FROM (SELECT DATE(ts) FROM t GROUP BY DATE(ts)) g").Scan(&groups); err != nil {
		panic(err)
	}

	fmt.Printf("[%s] loc=%s where_matched=%d date_groups=%d\n", label, loc, matched, groups)
}

func main() {
	// 同じ接続先に対して loc を変えても、サーバー側で確定する結果は変わらない。
	probeServerSide("source", os.Getenv("SOURCE_HOST"), "UTC")
	probeServerSide("source", os.Getenv("SOURCE_HOST"), "Asia%2FTokyo")
	probeServerSide("replica", os.Getenv("REPLICA_HOST"), "UTC")
	probeServerSide("replica", os.Getenv("REPLICA_HOST"), "Asia%2FTokyo")
}
```

**確認したいこと。**

| 接続先 | `loc` | `where_matched` | `date_groups` |
|---|---|---|---|
| ソース | `UTC` | 1 | 2 |
| ソース | `Asia/Tokyo` | **1**（変わらない） | **2**（変わらない） |
| レプリカ | `UTC` | 2 | 1 |
| レプリカ | `Asia/Tokyo` | **2**（変わらない） | **1**（変わらない） |

**同じ接続先なら `loc` を変えても結果が変わらず、接続先が変わると結果が変わる。** これはサーバー側の評価結果であり、ドライバの関与する余地がないことを意味する。Ruby の `database_timezone`、Python のアプリ側変換でも同様に、この差は吸収できない。

対処はドライバ設定ではなく、次のいずれかになる。

- **セッションのタイムゾーンを固定する。** 接続直後に `SET time_zone = '+00:00'` を実行し、リテラルの解釈基準を接続先によらず UTC に揃える
- **リテラルにタイムゾーンを含めない値を使う。** アプリケーション側で UTC の絶対時刻を計算し、`WHERE ts >= FROM_UNIXTIME(?)` のようにプレースホルダで UNIX 時刻を渡す

### 6-5. 3 言語の比較

| 言語 / ドライバ | タイムゾーン層 | サーバーへ `SET time_zone` を発行するか | 設定を誤った場合の症状 |
|---|---|---|---|
| Go / go-sql-driver | DSN の `loc`（既定 `UTC`） | `loc` は**発行しない**（クライアント側パースのみ）。DSN の `time_zone=%27...%27` は**発行する** | サーバーが変換した文字列を別のロケーションとして解釈し、**絶対時刻が silently ずれる** |
| Ruby / mysql2 | `database_timezone` / `application_timezone`（`:utc` か `:local` のみ） | **発行しない**（Ruby 側の変換のみ） | プロセスの `TZ` とサーバーのセッションが食い違い、絶対時刻がずれる |
| Python / PyMySQL | なし（naive `datetime` を返す） | **発行しない** | アプリケーションがタイムゾーンを付与しないと、`.timestamp()` などでプロセスのローカル時刻として誤解釈される |

**多くのドライバのタイムゾーンオプションは、サーバーのセッション状態に触れずクライアント側の変換だけを行う。** 例外は Java の Connector/J（`forceConnectionTimeZoneToSession=true`）と、Go の DSN で `time_zone` をシステム変数として渡した場合である。同じ DB へ複数言語からアクセスしているとここが揃わず、事故の原因になる。詳細は [mysql-timezone.md](mysql-timezone.md) の「クライアントライブラリとセッションタイムゾーン」を参照する。

### 吸収できる範囲とできない範囲

| 差異の発生箇所 | 例 | ドライバ設定で吸収できるか |
|---|---|---|
| 読み取り値の解釈 | `SELECT ts` の結果を時刻型へ変換する | **できる**（6-1〜6-3） |
| サーバー側での行の確定 | `WHERE ts >= 'リテラル'`、`GROUP BY DATE(ts)` | **できない**（6-4）。ドライバに渡る時点で既に行数が違う |

この境界が本手順の要点である。**ドライバ設定を正しくしても、`WHERE` 句や日付集計の差はいっさい解消しない。**

いずれの言語でも、**接続直後に `SET time_zone='+00:00'` でセッションを UTC に固定してしまえば、読み取り値・サーバー側評価の両方が接続先によらず揃う。** 接続先ごとにドライバ設定を変える運用より、こちらのほうが誤りが起きにくく、かつ吸収できない範囲まで含めて解決できる。

## 7. 後始末

**課金を止めるため必ず実施する。** レプリカ → ソース → パラメータグループの順に削除する（パラメータグループは DB インスタンスに関連付いている間は削除できない）。

```sh
# [変更] リードレプリカを削除する
aws rds delete-db-instance --db-instance-identifier tz-test-replica \
  --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier tz-test-replica

# [変更] ソースを削除する
aws rds delete-db-instance --db-instance-identifier tz-test-source \
  --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier tz-test-source

# [変更] パラメータグループを削除する
aws rds delete-db-parameter-group --db-parameter-group-name tz-test-replica-mysql84
aws rds delete-db-parameter-group --db-parameter-group-name tz-test-source-mysql84
```

削除後、残存リソースがないことを確認する。

```sh
aws rds describe-db-instances \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, 'tz-test')].DBInstanceIdentifier" \
  --output text

aws rds describe-db-parameter-groups \
  --query "DBParameterGroups[?starts_with(DBParameterGroupName, 'tz-test')].DBParameterGroupName" \
  --output text
```

`--manage-master-user-password` で作成した Secrets Manager のシークレットは、DB インスタンス削除時に削除がスケジュールされる。即時削除が必要な場合は個別に対応する。

## 8. 判定と記録

| 検証項目 | 手順 | 期待 | 成立すれば言えること |
|---|---|---|---|
| 内部表現の一致 | 4-1 | `UNIX_TIMESTAMP(ts)` が一致 | **データは壊れていない** |
| UTC 揃えでの一致 | 4-2 | 表示値が一致 | 差異はセッション表現のみ |
| 表示値の差 | 5-1 | `ts` は +9h、`dt` は同一 | 型によって挙動が変わる |
| `WHERE` の差 | 5-2 | 件数が 1 と 2 | **クエリ結果が変わる** |
| 集計の差 | 5-3 | グループ数が 2 と 1 | 日次集計が変わる |
| 読み取り値の吸収（Go） | 6-1 | `loc` を合わせれば両方 `match=true` | **設定が正しければ差は出ない** |
| 読み取り値の吸収（Ruby） | 6-2 | `database_timezone` を合わせれば両方 `match=true` | 同上 |
| 読み取り値の非吸収（Python） | 6-3 | `server_unix` は一致、`tzinfo` は両方 `None` | 吸収機構がなく、アプリ側の責務になる |
| **サーバー側評価は吸収不可** | 6-4 | 同じ接続先なら `loc` を変えても件数・グループ数が変わらない | **`WHERE`・日付集計の差はドライバ設定では解消しない** |

手順 4 が成立し手順 5 で差が出れば、「**データは一致するが、クライアントから見える表現とクエリの解釈だけが変わる**」という結論が実環境で確認できたことになる。

手順 6 まで実施すると、対処すべき範囲の切り分けまで確認できる。

- 読み取り値の解釈（6-1〜6-3）は、**ドライバ設定を接続先のセッション `time_zone` に合わせれば吸収できる**
- `WHERE` 句や `GROUP BY DATE()` の差（6-4）は、**ドライバ設定では吸収できない**。セッションのタイムゾーン固定か、リテラルを使わない書き方で対処するしかない

結果は作業チケットへ証跡として残す。

## 参考資料

- [mysql-timezone.md](mysql-timezone.md) — 本検証の対象となる仕様の整理
- [Amazon RDS ユーザーガイド — Local time zone for MySQL DB instances](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.LocalTimeZone.html)
- [Amazon RDS ユーザーガイド — Working with read replicas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html)
- [MySQL 8.4 Reference Manual — Replication and Time Zones](https://dev.mysql.com/doc/refman/8.4/en/replication-features-timezone.html)
