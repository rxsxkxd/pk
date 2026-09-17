# RDS for MySQL のスロークエリログ設定

## 対象と前提

本書は **RDS for MySQL 8.4** の DB パラメータグループで設定するスロークエリログと、その関連パラメータを整理する。
Aurora MySQL は対象外とする。

パラメータが実際に対象の RDS for MySQL 8.4 ファミリーで変更可能かどうかは、利用リージョン・エンジンファミリーの AWS API 結果を正とする。次の読み取り専用コマンドで `IsModifiable`、既定値、適用方法を確認する。

```sh
# mysql8.4 のスロークエリログ関連パラメータと、変更可否・適用方法を取得する
aws rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.4 \
  --query 'EngineDefaults.Parameters[?contains(ParameterName, `slow`) || ParameterName==`long_query_time` || ParameterName==`min_examined_row_limit` || ParameterName==`log_output` || ParameterName==`log_queries_not_using_indexes` || ParameterName==`log_throttle_queries_not_using_indexes` || ParameterName==`log_timestamps` || ParameterName==`log_raw`].[ParameterName,ParameterValue,IsModifiable,ApplyType,AllowedValues]' \
  --output table
```

## `slow_query_log` と `general_log` は別のログ

両者は `log_output` という共通パラメータで出力先の種類を選ぶが、**有効化する設定、出力先の実体、記録するデータの意味・形式は別**である。

| 観点 | `slow_query_log`（スロークエリログ） | `general_log`（一般ログ） |
| --- | --- | --- |
| 有効化 | `slow_query_log=1` | `general_log=1` |
| 記録対象 | 実行時間などの条件に合う SQL | 接続・切断およびサーバーが受信した SQL 全般 |
| 主な用途 | 性能劣化した SQL の特定・チューニング | 短時間の障害解析、クライアントが送った SQL の確認 |
| `FILE` 出力 | スロークエリ用の独立したログファイル | 一般ログ用の独立したログファイル |
| `TABLE` 出力 | `mysql.slow_log` | `mysql.general_log` |
| 記録形式 | SQL に加え `Query_time`、`Lock_time`、`Rows_sent`、`Rows_examined` などの実行統計を持つ | 時刻、接続 ID、接続元、受信した SQL が中心で、実行統計は持たない |
| CloudWatch Logs のログ種別 | `slowquery` | `general` |
| 通常運用での扱い | 継続的な性能監視の候補 | ログ量が大きいため、原則として常時有効化しない |

`general_log` を有効にしても `slow_query_log` は有効にならず、その逆も成立しない。性能調査のために必要なのは通常 `slow_query_log` であり、`general_log` はスロークエリログの関連設定には含めない。

## スロークエリログの関連パラメータ

### 記録の有効化・出力先

| パラメータ | 既定値 | 内容 | 運用上の注意 |
| --- | --- | --- | --- |
| `slow_query_log` | `0` / `OFF` | スロークエリログを有効化する。 | `1` / `ON` にしなければ、他の設定をしてもスロークエリは出力されない。 |
| `log_output` | MySQL 8.4 は `FILE` | 出力先を `FILE`、`TABLE`、`NONE` から選ぶ。`FILE,TABLE` のように複数指定も可能。 | RDS コンソール・API・AWS CLI からログファイルを扱う場合、および CloudWatch Logs へエクスポートする場合は `FILE` を選ぶ。`TABLE` は DB ストレージと書込み負荷を増やす。 |

### 記録する SQL の選別

| パラメータ | 既定値 | 内容 | 運用上の注意 |
| --- | --- | --- | --- |
| `long_query_time` | `10` 秒 | この値より実行時間が長い SQL を記録するしきい値。 | `FILE` 出力ではマイクロ秒精度の小数を指定できる。低くしすぎるとログ量・I/O が増える。 |
| `min_examined_row_limit` | `0` | この行数以上を検査した SQL だけを記録する。 | 小さなテーブルへのクエリを除外したい場合に使う。`0` はこの条件で除外しない。 |
| `log_queries_not_using_indexes` | `0` / `OFF` | インデックスで行の絞り込みをしない SQL を記録対象に追加する。 | `long_query_time` 未満でも記録され得るため、ログ量の急増に注意する。 |
| `log_throttle_queries_not_using_indexes` | `0` | `log_queries_not_using_indexes` により記録される SQL の最大件数（毎分）。`0` は無制限。 | 非インデックス検索の調査時は、ログ肥大化を避けるため正の値を検討する。 |
| `log_slow_admin_statements` | `0` / `OFF` | 遅い `ALTER TABLE`、`ANALYZE TABLE`、`OPTIMIZE TABLE` などの管理 SQL も記録する。 | DDL・メンテナンスの所要時間を調べる場合に有用。 |
| `log_slow_replica_statements` | `0` / `OFF` | レプリカで適用する SQL をスロークエリログに記録する。 | `binlog_format=ROW` ではレプリカに SQL として適用されないため、実質的に記録されない。MySQL 8.4 の名称を使用する。 |

スロークエリログに書かれるかは、概ね次の順で判断される。

1. 管理 SQL なら `log_slow_admin_statements` が有効である。
2. `long_query_time` を超える、または `log_queries_not_using_indexes` に該当する。
3. `min_examined_row_limit` 以上の行を検査した。
4. `log_throttle_queries_not_using_indexes` により抑制されていない。

### 記録内容・時刻・機密情報に影響する設定

| パラメータ | 既定値 | 内容 | 運用上の注意 |
| --- | --- | --- | --- |
| `log_slow_extra` | `0` / `OFF` | `FILE` 出力のスロークエリログに、追加の実行情報を付加する。 | `TABLE` 出力には影響しない。詳細解析時に有用だが、ログ形式・容量への影響を確認する。 |
| `log_timestamps` | `UTC` | `FILE` 出力における時刻のタイムゾーンを `UTC` または `SYSTEM` にする。 | `TABLE` 出力には影響しない。CloudWatch Logs や監視基盤の時刻と合わせる。 |
| `log_raw` | `0` / `OFF` | SQL 中のパスワード等のマスク方法に関わるログ設定。 | 機密情報をログに残すリスクがあるため、原則として `OFF` を維持する。 |

## CloudWatch Logs へ出力する場合

パラメータグループだけでは CloudWatch Logs への出力は完結しない。DB インスタンスで CloudWatch Logs export の `slowquery` を有効化する必要がある。

最低限、次の組み合わせとする。

```yaml
# DB パラメータグループ
slow_query_log: '1'
long_query_time: '1.0'
log_output: FILE

# DB インスタンスの CloudWatch Logs export
EnableCloudwatchLogsExports:
  - slowquery
```

`general` を export 対象に追加するのは、`general_log=1` を一時的に有効化している期間だけに限定する。general log はすべての受信 SQL を多量に記録し、性能およびログ保管コストへ影響し得る。

## RDS で利用者が設定しない項目

`slow_query_log_file` と `general_log_file` は MySQL のシステム変数であるが、RDS ではログのファイルパス・ファイル名を利用者が管理する運用ではない。本書の CloudFormation パラメータグループ定義には含めない。

## 参考資料

- [RDS for MySQL のログ概要](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.MySQL.LogFileSize.html)
- [RDS for MySQL ログの CloudWatch Logs への公開](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.MySQLDB.PublishtoCloudWatchLogs.html)
- [MySQL 8.4: The Slow Query Log](https://dev.mysql.com/doc/refman/8.4/en/slow-query-log.html)
- [MySQL 8.4: The General Query Log](https://dev.mysql.com/doc/refman/8.4/en/query-log.html)
