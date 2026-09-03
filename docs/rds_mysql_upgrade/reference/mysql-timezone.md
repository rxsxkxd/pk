# RDS for MySQL のタイムゾーン設定

## 対象と前提

本書は **RDS for MySQL 8.4** の DB パラメータグループとセッションで設定するタイムゾーン関連パラメータを整理する。Aurora MySQL は対象外とする。

> 「`time_zone` を `Asia/Tokyo` に変更してよいか」という判断だけが必要な場合は、要約版の [mysql-timezone-problem-summary.md](mysql-timezone-problem-summary.md) を先に読む。

パラメータが実際に対象の RDS for MySQL 8.4 ファミリーで変更可能かどうかは、利用リージョン・エンジンファミリーの AWS API 結果を正とする。次の読み取り専用コマンドで `IsModifiable`、既定値、適用方法を確認する。

```sh
# mysql8.4 のタイムゾーン関連パラメータと、変更可否・適用方法を取得する
aws rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.4 \
  --query 'EngineDefaults.Parameters[?ParameterName==`time_zone` || ParameterName==`explicit_defaults_for_timestamp` || ParameterName==`log_timestamps`].[ParameterName,ParameterValue,IsModifiable,ApplyType,AllowedValues]' \
  --output table
```

## パラメータ一覧

| パラメータ名 | 種別 | MySQL 8.4 既定値 | RDS での既定値 | 説明 |
|---|---|---|---|---|
| `time_zone` | DB パラメータグループ（動的）／セッション変数 | `SYSTEM` | **`UTC`** | サーバーおよび接続のタイムゾーン。`NOW()`、`CURRENT_TIMESTAMP`、`TIMESTAMP` 型の入出力変換に影響する。 |
| `system_time_zone` | 読み取り専用のシステム変数（Global、Dynamic: No） | ホスト依存 | `UTC` | サーバープロセスが起動時にホストから継承したタイムゾーン。確認用であり、設定はできない。 |
| `explicit_defaults_for_timestamp` | DB パラメータグループ（動的）／セッション変数 | `ON` | `ON` | `TIMESTAMP` 列の `NULL` 許容と `DEFAULT CURRENT_TIMESTAMP` 自動付与に関する非標準挙動を無効化する。**MySQL 8.4 で非推奨**（後述）。 |

`time_zone` の既定値は、MySQL 本体（上流）では `SYSTEM` だが、**RDS では `UTC`** である。RDS のホスト時刻自体も UTC のため、実効値としては同じ UTC になる。

### `default_time_zone` というシステム変数は存在しない

`default_time_zone` という名前のシステム変数は MySQL 8.4 に存在しない（8.4 リファレンスマニュアルのシステム変数一覧に該当なし）。混同されやすいものが 2 つある。

| 混同されやすい名前 | 実体 | RDS での扱い |
|---|---|---|
| `--default-time-zone` | mysqld の**起動オプション**。グローバル `time_zone` の初期値を決める。`SHOW VARIABLES` では参照できない | RDS はマネージドサービスのため起動オプションを指定できない。代わりに `time_zone` パラメータを使う |
| `system_time_zone` | **読み取り専用のシステム変数**。サーバーがホストから継承した時刻帯 | 参照のみ可能。値は `UTC` |

「サーバー起動時のタイムゾーンを読み取り専用で確認する」用途に対応するのは `system_time_zone` である。

## `TIMESTAMP` と `DATETIME` の挙動の違い

`time_zone` の設定が影響するのは `TIMESTAMP` 型であり、`DATETIME` 型には影響しない。

| データ型 | 内部の保存形式 | `time_zone` の影響 |
|---|---|---|
| `TIMESTAMP` | 常に UTC で保存される | **あり**。書き込み時に接続の `time_zone` から UTC へ、読み取り時に UTC から接続の `time_zone` へ変換される |
| `DATETIME` | 指定された値をそのまま保存する | **なし**。タイムゾーン変換は行われない |

このため、`time_zone` を変更すると、**既存の `TIMESTAMP` 列の見え方だけが変わる**。保存済みのデータそのものは書き換わらないが、アプリケーションが受け取る値は変わる。`DATETIME` 列は変更前後で同じ値を返す。

## 設定方法

### 1. DB パラメータグループで設定する（インスタンス全体）

カスタムパラメータグループの `time_zone` に、RDS がサポートする値を設定する。CloudFormation を唯一の変更経路とする本リポジトリの方針では、[phase-1-parameter-group-cloudformation.md](../phase-1-parameter-group-cloudformation.md) の手順に従う。

RDS がサポートする値は、`UTC` と IANA の名前付きタイムゾーン（`Asia/Tokyo`、`Asia/Seoul`、`America/Denver` など）に限定された一覧である。**`SYSTEM` はこの一覧に含まれていない。** 最新の一覧は [AWS の公式ドキュメント](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.LocalTimeZone.html)を参照する。

> **「動的パラメータだから即時反映される」は不正確である。** `time_zone` は `ApplyType: dynamic` のため再起動は不要だが、**変更が見えるのは新規接続からである**。変更時点で開いている接続は、切断して再接続するまで従来のタイムゾーンを使い続ける。コネクションプールを使うアプリケーションでは、プール内の既存接続が入れ替わるまで新旧のタイムゾーンが混在しうる。

### 2. セッション単位で設定する（接続ごと）

DB 全体を変更せず、特定の接続だけタイムゾーンを変えたい場合に使う。

```sql
-- セッション単位で日本時間に設定する
SET time_zone = 'Asia/Tokyo';

-- 確認する
SELECT @@global.time_zone AS global_tz,
       @@session.time_zone AS session_tz,
       @@system_time_zone AS system_tz,
       NOW() AS now_value;
```

名前付きタイムゾーン（`Asia/Tokyo` など）を使うには `mysql.time_zone_*` テーブルがロードされている必要があるが、**RDS では AWS が事前にロード済み**のため、`mysql_tzinfo_to_sql` の実行は不要である。ロード状況は次で確認できる。

```sql
SELECT COUNT(*) FROM mysql.time_zone_name;  -- 0 より大きければロード済み
```

## RDS 固有の注意点

- **`SET GLOBAL time_zone` は実行できない。** グローバル値の変更には `SUPER` 権限が必要だが、RDS のマスターユーザーには付与されない。変更経路は DB パラメータグループの `time_zone` パラメータだけである。セッション単位の `SET time_zone` は通常のユーザーで実行できる。
- **`system_time_zone` は UTC 固定である。** RDS はホスト OS のタイムゾーンを変更する手段を提供しない。
- **タイムゾーンデータ（IANA）の更新は、エンジンバージョンのアップグレード時にのみ行われる。** RDS は稼働中の DB インスタンスのタイムゾーンデータを更新・リセットしない。マイナーメンテナンスリリースには当時点の最新データが同梱されるため、データを新しく保つにはエンジンバージョンを上げる必要がある。
- **スナップショットから復元すると `time_zone` は UTC にリセットされる。** 一方、ポイントインタイムリカバリ（PITR）で復元した場合は、復元先インスタンスに関連付けられたパラメータグループの設定が使われる。
- パラメータグループは複数のインスタンスで共有されるため、**同じパラメータグループを使う DB インスタンスとリードレプリカはすべて同時に変更される。** インスタンスとレプリカで別のタイムゾーンにしたい場合は、別々のパラメータグループを割り当てる。
- クロスリージョンレプリケーションではパラメータグループがリージョンごとに独立するため、両方のリージョンで個別に `time_zone` を設定する必要がある。

## レプリケーション構成でソースとレプリカの `time_zone` が異なる場合

ソース（例: `time_zone` 未設定 = RDS 既定の `UTC`）とレプリカ（例: `time_zone = Asia/Tokyo`）で設定が異なる構成を想定する。

> 本節の内容を実際の AWS 環境で検証する手順は [mysql-timezone-replication-verification.md](mysql-timezone-replication-verification.md) にまとめてある。

### 保存されるデータは一致する

**両者に保存される実データは同一であり、値がずれることはない。** 理由は 2 つある。

1. **`time_zone` は保存形式を変えない。** 前掲のとおり `TIMESTAMP` は常に UTC で保存され、変換は入出力時にだけ行われる。`DATETIME` はそもそも変換されない。
2. **レプリカ側の `time_zone` でイベントが再解釈されることはない。**

| バイナリログ形式 | レプリカでの扱い |
|---|---|
| `ROW` | ソースが解決済みの行イメージを書き込むため、レプリカは受け取った値をそのまま適用する。再解釈の余地がない |
| `STATEMENT` / `MIXED` | ソースは、実行時にセッションタイムゾーンが使われた場合、そのタイムゾーンを Query イベントに記録する。レプリカはソースのタイムゾーンで再実行するため、レプリカ自身の設定は適用されない |

加えて RDS のリードレプリカは `read_only` が強制されるため、クライアントがレプリカへ直接書き込む経路が存在しない。レプリカのデータはすべてレプリケーション経由で入る。

### 差が出るのはクライアントから見える表現とクエリの解釈である

データが同じでも、**接続先によって同じ行が違って見え、同じクエリが違う結果を返す**。以降は、挙動が変わるものを網羅的に列挙する。

#### 判定の原則

影響の有無は、次の 1 点だけで判定できる。

> **セッションの `time_zone` を経由して変換が発生するか。**

MySQL のリファレンスマニュアルは次のように定義している。

> The session time zone setting affects display and storage of time values that are zone-sensitive. This includes the values displayed by functions such as `NOW()` or `CURTIME()`, and values stored in and retrieved from `TIMESTAMP` columns. (中略) The session time zone setting does not affect values displayed by functions such as `UTC_TIMESTAMP()` or values in `DATE`, `TIME`, or `DATETIME` columns.

#### 1. 影響を受ける関数

すべて「セッションの `time_zone` を基準に値を返す／引数を解釈する」ものである。

| 関数 | 変わり方 |
|---|---|
| `NOW()` | 現在時刻をセッションのタイムゾーンで返す |
| `CURRENT_TIMESTAMP`、`CURRENT_TIMESTAMP()` | `NOW()` の同義語 |
| `LOCALTIME`、`LOCALTIME()`、`LOCALTIMESTAMP`、`LOCALTIMESTAMP()` | `NOW()` の同義語 |
| `SYSDATE()` | 同上（`NOW()` との違いは「文開始時刻」か「実行時刻」かであり、タイムゾーン依存性は同じ） |
| `CURDATE()`、`CURRENT_DATE`、`CURRENT_DATE()` | 現在日付をセッションのタイムゾーンで返す。**日付境界がずれるため、日単位の集計が変わる** |
| `CURTIME()`、`CURRENT_TIME`、`CURRENT_TIME()` | 現在時刻（時刻部）をセッションのタイムゾーンで返す |
| `FROM_UNIXTIME(epoch)` | UNIX 時刻をセッションのタイムゾーンの日時文字列へ変換する |
| `UNIX_TIMESTAMP(date)` | **引数をセッションのタイムゾーンの値として解釈**して UNIX 時刻へ変換する（例外は後述） |
| `CONVERT_TZ(dt, from, to)` | 引数に `@@session.time_zone` を渡している場合のみ影響を受ける。固定文字列だけなら影響しない |

#### 2. 影響を受けない関数

| 関数 | 理由 |
|---|---|
| `UTC_TIMESTAMP()`、`UTC_DATE()`、`UTC_TIME()` | 常に UTC を返す。マニュアルが明示的に「影響しない」と記載している |
| `UNIX_TIMESTAMP()`（**引数なし**） | 現在の UNIX 時刻という絶対値を返す。変換が発生しない |
| `UNIX_TIMESTAMP(timestamp_column)` | **引数が `TIMESTAMP` 列の場合、内部表現をそのまま返す**（文字列変換を経由しない）。同じ関数でもリテラルや `DATETIME` 列を渡した場合とは挙動が違う |

#### 3. 列の型による違い

| 型 | 読み出し | 書き込み |
|---|---|---|
| `TIMESTAMP` | UTC → セッションのタイムゾーンへ変換される。**接続先でずれる** | セッションのタイムゾーン → UTC へ変換して保存される |
| `DATETIME`、`DATE`、`TIME`、`YEAR` | 変換されない。**接続先が違っても同じ値** | 変換されない |

`TIMESTAMP` 列はずれるが `DATETIME` 列はずれないため、**同じ結果セットの中で列の型によって挙動が変わる**非対称が生じる。両方の型を持つテーブルを跨いで比較・結合している場合は特に注意する。

#### 4. `TIMESTAMP` 列を経由することで間接的に影響を受ける関数

以下の関数自体はタイムゾーン非依存だが、**`TIMESTAMP` 列に適用すると、変換後の値に対して評価される**ため、接続先によって結果が変わる。`DATETIME` 列に適用した場合は変わらない。

```sql
-- ts が TIMESTAMP 型の場合、接続先によって結果が変わる
SELECT DATE(ts), YEAR(ts), MONTH(ts), DAY(ts), HOUR(ts),
       DATE_FORMAT(ts, '%Y-%m-%d'), EXTRACT(DAY FROM ts),
       WEEK(ts), DAYOFWEEK(ts), DAYNAME(ts)
FROM t;
```

とくに `DATE(ts)` や `DATE_FORMAT(ts, '%Y-%m-%d')` は、**日付の切り替わりが 9 時間ずれる**ため、日次集計の対象行が変わる。`GROUP BY DATE(ts)` を使った集計は、接続先によって集計結果そのものが変わる。

#### 5. 日時リテラルとの比較（最も実害が出やすい）

`TIMESTAMP` 列と日時リテラルを比較すると、**リテラルがセッションのタイムゾーンで解釈される**。次のクエリは、接続先によって異なる絶対時刻を指す。

```sql
-- ソース  : 2026-09-03 00:00:00 UTC を意味する
-- レプリカ: 2026-09-03 00:00:00 JST（= 2026-09-02 15:00:00 UTC）を意味する
SELECT * FROM t WHERE ts >= '2026-09-03 00:00:00';
```

データは一致しているのに、**返る行が変わる**。同じことが次の箇所すべてで起きる。

- `WHERE` 句の比較・`BETWEEN`
- `JOIN ... ON` の結合条件
- `HAVING` 句
- `INSERT` / `UPDATE` で `TIMESTAMP` 列へ渡すリテラル（**書き込む絶対時刻がずれる**）
- `ORDER BY` の対象がリテラル比較を含む式である場合

読み取りをレプリカへ振り分けているアプリケーションでは、経路によって結果が変わる不具合になり、しかもデータ不整合として検知されないため発見が遅れやすい。

#### 6. スキーマ定義に埋め込まれるもの（`DEFAULT CURRENT_TIMESTAMP`）

`DEFAULT CURRENT_TIMESTAMP` と `ON UPDATE CURRENT_TIMESTAMP` は `NOW()` と同じ評価を受ける。**ただし列の型によって安全性が正反対になる。**

| 列の型 | 挙動 | 安全性 |
|---|---|---|
| `TIMESTAMP` | セッションの `time_zone` で `NOW()` を評価し、**UTC へ変換して格納**する | **安全**。どのセッションが INSERT しても同じ絶対時刻になる。読み出し時に各セッションのタイムゾーンへ戻されるだけ |
| `DATETIME` | `NOW()` の結果を**そのまま壁時計として格納**する。変換は起きない | **危険**。INSERT したセッションのタイムゾーンによって保存値そのものが変わる |

`DATETIME` 列で危険なのは、**同じ列に異なるタイムゾーンの壁時計が混在しうる**点である。

- アプリケーションが UTC で明示的に値を入れた行 → UTC の壁時計
- `time_zone = Asia/Tokyo` の別セッションが `DEFAULT` 任せで INSERT した行 → JST の壁時計

この 2 つが同じ列に並ぶ。読み出す側は列の値だけからどちらか判別できず、アプリケーションが一律 UTC とみなしていれば後者は 9 時間ずれた時刻として解釈される。**データ不整合として検知されないまま蓄積する**ため、発見が遅れやすい。

RDS のリードレプリカは読み取り専用のため書き込みは発生しないが、Blue/Green の切替後や、レプリカを昇格させた場合には該当する。

対処は次のいずれかである。

- 列を `TIMESTAMP` にする（内部 UTC 保存になるため混在しない）
- DB 側の `DEFAULT` に頼らず、アプリケーション側で常に値を入れる
- パラメータグループで `time_zone` を UTC に固定し、全接続のタイムゾーンを揃える

> この混在は **Rails なしで、素の SQL だけで再現できる**。実機での確認手順は [examples/mysql-timezone-replication/](../examples/mysql-timezone-replication/) の「`DEFAULT CURRENT_TIMESTAMP` の混在検証」にある。

#### 7. アプリケーションのドライバ設定で吸収できる範囲

| 差異の発生箇所 | 例 | ドライバ設定で吸収できるか |
|---|---|---|
| 読み取り値の解釈 | `SELECT ts` の結果を時刻型へ変換する | **できる**（設定を接続先のセッション `time_zone` に合わせた場合） |
| サーバー側での行の確定 | 上記 5 の `WHERE`・`JOIN`、上記 4 の `GROUP BY DATE(ts)` | **できない**。ドライバに渡る時点で既に行数が違う |

「ドライバの設定さえ正しくすれば安全」とは言えない。`WHERE` 句のリテラル解釈と日付集計の差は、**接続直後に `SET time_zone` でセッションを固定する**か、リテラルを使わずに UNIX 時刻をプレースホルダで渡す形にしない限り解消しない。

ドライバごとの詳細は後述の「クライアントライブラリとセッションタイムゾーン」を参照する。実機での確認手順は [mysql-timezone-replication-verification.md](mysql-timezone-replication-verification.md) の手順 6 にある。

#### 8. まとめ: 紛らわしい 3 点

| 紛らわしい点 | 正しい理解 |
|---|---|
| `UNIX_TIMESTAMP()` は影響を受けるのか | **引数の有無と型で変わる。** 引数なしと `TIMESTAMP` 列を渡した場合は影響なし。リテラルや `DATETIME` 列を渡した場合は影響あり |
| `DATE()` や `YEAR()` はタイムゾーンに依存しないのでは | **関数自体は非依存だが、`TIMESTAMP` 列に適用すると変換後の値を見るため影響を受ける。** `DATETIME` 列なら影響なし |
| `DATETIME` を使っていれば安全か | **列の読み書きは安全だが、`NOW()` や `CURDATE()` で値を作っている箇所は影響を受ける。** 型ではなく「値がどこから来たか」で判断する |

### `SYSTEM` を指定した場合の追加の危険

MySQL のリファレンスマニュアルは、`time_zone` に `SYSTEM` を指定した構成について明示的に警告している。`SYSTEM` は各サーバーが自分の `system_time_zone` を参照する**シンボリックな値**であり、ソースとレプリカでホストのタイムゾーンが異なると、グローバル値が一致していても結果がずれる。

RDS ではホストのタイムゾーンが常に UTC のためこの問題は顕在化しないが、そもそも `SYSTEM` は RDS のサポート値一覧に含まれていない（前掲）。

### 推奨

MySQL のリファレンスマニュアルは、ソースとレプリカで同じタイムゾーン設定にすることを推奨している。意図的に変える場合は、前掲の 1〜8 を踏まえて次を確認する。

- `TIMESTAMP` 列に対する日時リテラルの比較（`WHERE`、`BETWEEN`、`JOIN ... ON`、`HAVING`）が存在しない、または明示的に UTC で指定している
- `GROUP BY DATE(ts)` のように、`TIMESTAMP` 列から日付を切り出して集計している箇所がない（日付境界がずれて集計結果が変わる）
- `NOW()`、`CURDATE()`、`FROM_UNIXTIME()` を含むクエリの結果を、接続先を跨いで比較・キャッシュしていない
- アプリケーションが `TIMESTAMP` 列の値をタイムゾーン込みで解釈している（受け取った文字列をそのまま保存・比較していない）

該当箇所の洗い出しには、アプリケーションのソースに対する次の grep が起点として使える。ただし ORM が生成するクエリは検出できないため、最終的には実際に発行される SQL で確認する。

```sh
grep -rniE "now\(\)|curdate\(\)|current_date|curtime\(\)|current_time|sysdate\(\)|localtime|from_unixtime|unix_timestamp|convert_tz" <アプリケーションのソース>
```

## クライアントライブラリとセッションタイムゾーン

前節までは「サーバー側の `time_zone` が何であるか」の話である。ここでは、**アプリケーションが接続したときに、そのセッションの `time_zone` が実際に何になるか**を扱う。レプリケーションの有無に関係なく当てはまる。

### 前提: クライアント OS の `TZ` は MySQL に送られない

クライアント側の `TZ` 環境変数は、MySQL プロトコル上でサーバーへ送られることはない。したがって、**ドライバが明示的に `SET time_zone` を発行しない限り、セッションの `time_zone` はサーバーのグローバル値のままである。**

`mysql` コマンドラインクライアントも `SET time_zone` を発行しない。このため CLI で確認した `NOW()` は「グローバル設定での見え方」と一致する（アプリケーション側のライブラリが上書きしていない限り、アプリから見える値とも一致する）。

### ドライバが `SET time_zone` を発行するかどうか

ここが最も誤解されやすい。**多くのドライバのタイムゾーンオプションは、サーバーのセッション状態に触れず、クライアント側の変換だけを行う。**

| ドライバ | サーバーへ `SET time_zone` を発行するか | 該当する設定 |
|---|---|---|
| Connector/J（Java） | **する** | `connectionTimeZone` ＋ `forceConnectionTimeZoneToSession=true` |
| go-sql-driver/mysql（Go） | **する**（DSN のシステム変数として） | `time_zone=%27Asia%2FTokyo%27`。一方 `loc` はクライアント側パースのみで**発行しない** |
| mysql2（Ruby） | **しない** | `database_timezone` / `application_timezone` は Ruby 側の変換のみ |
| PyMySQL / mysqlclient（Python） | **しない** | タイムゾーン層を持たず、naive な `datetime` を返す |
| mysql2（Node.js） | **しない** | クライアント側変換のみ |

**同一の DB へ複数の言語からアクセスしている場合、ここが揃っていないことが典型的な事故要因になる。** Java からの接続だけセッションが `Asia/Tokyo` になり、Ruby と Python からの接続はサーバーのグローバル値のまま、という状態が容易に発生する。

### Ruby on Rails（mysql2 アダプタ）の場合

`ActiveRecord` は**既定でセッションの `time_zone` を設定しない**。`abstract_mysql_adapter.rb` の `configure_connection` は `sql_mode`・`wait_timeout`・`variables` に指定された値を `SET` するが、`time_zone` は扱わない（Rails 5.2 / 6.1 / 7 系以降のいずれでもファイル内に `time_zone` の記述がないことを確認済み）。代わりに `default_timezone`（既定 `:utc`）に従い、**Ruby 側で UTC 文字列へ変換してから INSERT し、UTC として読み戻す**。

このため、**Rails が読み書きする値についてはセッション `time_zone` が何であっても壊れない**。危険なのは**サーバー側で値が生成される箇所**だけである。

- `NOW()`、`CURRENT_TIMESTAMP` を含む生 SQL
- `DEFAULT CURRENT_TIMESTAMP` / `ON UPDATE CURRENT_TIMESTAMP`（前掲 6 の `DATETIME` 列の混在に注意）
- 日次集計などの `DATE()` / `GROUP BY`

セッションを明示的に固定したい場合は `database.yml` の `variables` を使う。アダプタはここに書いた値を `SET @@SESSION.<名前> = <値>` として発行する。

```yaml
production:
  adapter: mysql2
  variables:
    time_zone: "+00:00"
```

Rails 固有の注意として、`t.timestamps` が作るのは **`datetime` 列**であり、値は Ruby 側から UTC で入る。ここに後から DB 側のデフォルトを足すと、前掲 6 の混在が発生しうる。

```ruby
# これを足すと、Ruby 由来の UTC 値と DB 由来のセッション TZ 値が同じ列に混ざりうる
change_column_default :users, :created_at, -> { "CURRENT_TIMESTAMP" }
```

DB 側のデフォルトに寄せたいなら、列を `TIMESTAMP` にするか、パラメータグループで `time_zone` を UTC に固定して全接続を揃えるかのいずれかにする。あわせて、**DB 側で生成された値は `reload` するまで ActiveRecord のオブジェクトに反映されない**点も運用上効いてくる。

## 運用方針の推奨

**RDS 側は UTC のまま運用し、表示だけアプリケーション側で JST にするのが安全側である。**

`time_zone = Asia/Tokyo` に変更すると、次の問題が同時に発生しうる。

- `DATETIME` 列に、アプリケーション由来の UTC 値と `NOW()` 由来の JST 値が混在する（前掲 6）
- `WHERE` 句の日時リテラルの解釈が変わり、クエリ結果が変わる（前掲 5）
- `GROUP BY DATE()` の日境界がずれ、日次集計が変わる（前掲 4）

一方、表示のためだけであればアプリケーション側で完結する（Rails なら `config.time_zone`）。DB のタイムゾーンを動かす必要はない。

### アプリケーション側の確認項目

移行前後で次を確認する。

```sql
SELECT @@system_time_zone, @@global.time_zone, @@session.time_zone, NOW(), UTC_TIMESTAMP();
```

Rails の場合は加えて次を確認する。

```ruby
# Rails 5.2 / 6.1 の API。7.0 以降は ActiveRecord.default_timezone へ移動している。
ActiveRecord::Base.default_timezone                          # :utc であること
Rails.application.config.time_zone                           # 表示用。'Tokyo' など
ActiveRecord::Base.connection.select_value("SELECT NOW()")   # Time.current と比較する

# セッションに time_zone が設定されていないことの確認（既定では設定されない）
ActiveRecord::Base.connection.select_value("SELECT @@session.time_zone")
```

> `default_timezone` の参照先は Rails のバージョンで変わる。**5.2・6.1 は `ActiveRecord::Base.default_timezone`**、7.0 以降は `ActiveRecord.default_timezone` である（既定値はどちらも `:utc`）。

棚卸しの対象。

- `schema.rb` / `structure.sql` を `CURRENT_TIMESTAMP` で grep する
- 列型が `timestamp` か `datetime` かを棚卸しする（前掲 6 の安全性が正反対になるため）
- 生 SQL 内の `NOW()` / `CURDATE()` / `DATE()` を洗い出す。とくに日次集計の日境界
- cron・バッチサーバーの OS のタイムゾーンと、そこから起動するプロセスの `TZ` 環境変数
- 外部ツール（BI、Redash、ワークフローエンジン、運用スクリプトの直 SQL）が同じタイムゾーンで接続しているか

## MySQL 8.0 → 8.4 移行での注意点

### `explicit_defaults_for_timestamp` は 8.4 で非推奨である

MySQL 8.4 リファレンスマニュアルでは、このシステム変数に `Deprecated: Yes` が明記されている。既定値は `ON` のままで、`ON` が標準 SQL 準拠の挙動である。

- `OFF` に設定すると**警告が出る**。
- `OFF` のときに有効になる非標準挙動（先頭 `TIMESTAMP` 列への `DEFAULT CURRENT_TIMESTAMP` / `ON UPDATE CURRENT_TIMESTAMP` の自動付与、`TIMESTAMP NOT NULL` への `NULL` 代入が現在時刻になる、など）は、将来の MySQL リリースで削除される予定である。

現行 8.0 のパラメータグループでこれを `0`（`OFF`）に設定している場合、**8.4 への移行時に非推奨設定を引き継ぐことになる**。8.4 では動作するが、次のメジャーバージョンで動かなくなる可能性が高いため、移行の機会にアプリケーション側の `TIMESTAMP` 列定義を見直し、`ON`（既定）へ寄せられるかを判断する。判断結果は Step 2 のレビューで証跡として残す。

### `time_zone` は本リポジトリの生成器が自動的に引き継ぐ

`config/mysql80-to-84-parameter-rules.yml` に `time_zone` のルールは登録していない。`generate_mysql84_parameter_group.rb` はルール未登録の `Source=user` パラメータを既定で `copy`（同名で 8.4 へ反映）として扱うため、8.0 側で `time_zone` を明示設定していれば、生成される 8.4 のテンプレートにも同じ値が入る。

ただし次の点は生成器では担保されないため、Step 2 のレビューで確認する。

- 8.0 側で `time_zone` を**明示設定していない**（`Source=engine-default` の）場合、収集対象にならないため 8.4 でも既定の `UTC` になる。これが意図どおりかを確認する。
- 生成された値が RDS のサポート値一覧に含まれているかを確認する。

### Blue/Green Deployment 実行時の確認

Blue/Green Deployment は Blue → Green のレプリケーションで構成されるため、前掲「レプリケーション構成で `time_zone` が異なる場合」がそのまま当てはまる。Green には別ファミリー（`mysql8.4`）のパラメータグループを割り当てるため、**設定差が生まれやすい構成**である点に注意する。

- **Green のデータが壊れることはない。** Blue → Green のレプリケーションで値が再解釈されることはなく、`TIMESTAMP` は両側とも UTC で保存される。検証中に Green を読んで値がずれて見えても、それは表現の違いであってデータの不一致ではない。
- **危険なのは切替の瞬間である。** 切替は無停止に近い形で行われるため、Blue と Green で `time_zone` が異なると、アプリケーションから見える `TIMESTAMP` 値と日時リテラルの解釈が**切替と同時に変わる**。ダウンタイムを伴わないぶん、原因の切り分けが難しい形で顕在化する。
- Step 4（`verify_green.sh`）が生成する検証レポートで、Green 側の `time_zone` が Blue と一致しているかを確認する。DB へ接続して実効値を収集する場合は `--mysql-user` を指定する（既定では収集しない）。
- 保護スナップショットから復元して切り戻す経路を採る場合、**復元後のインスタンスは `time_zone` が UTC にリセットされる**（前掲の RDS 仕様）。Blue が `Asia/Tokyo` だった場合、復元しただけでは元の状態に戻らない。復元後にパラメータグループを関連付け直すか、`time_zone` を再設定する必要がある。

## 参考資料

- [MySQL 8.4 Reference Manual — MySQL Server Time Zone Support](https://dev.mysql.com/doc/refman/8.4/en/time-zone-support.html)
- [MySQL 8.4 Reference Manual — Server System Variables (`system_time_zone`, `explicit_defaults_for_timestamp`)](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html)
- [MySQL 8.4 Reference Manual — Automatic Initialization and Updating for TIMESTAMP and DATETIME](https://dev.mysql.com/doc/refman/8.4/en/timestamp-initialization.html)
- [MySQL 8.4 Reference Manual — Replication and Time Zones](https://dev.mysql.com/doc/refman/8.4/en/replication-features-timezone.html)
- [Amazon RDS ユーザーガイド — Local time zone for MySQL DB instances](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.LocalTimeZone.html)
