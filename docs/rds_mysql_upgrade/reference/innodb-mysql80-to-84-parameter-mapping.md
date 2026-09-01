# RDS for MySQL 8.0 → 8.4 InnoDB パラメータマッピング

## 目的と範囲

RDS for MySQL 8.0 の DB パラメータグループから MySQL 8.4 用グループを作成する際、InnoDB 関連パラメータをどのように扱うかを定める。本書はパラメータグループの値だけを対象とし、DB インスタンスへの関連付け、再起動、性能試験の実施は対象外とする。

値は次の3種類を区別する。

- **`Source=user`**: 現行カスタムグループで明示した値。移行判断の入力となる。
- **engine default**: `describe-engine-default-parameters` が返す MySQL ファミリーの既定値。
- **`Source=system`**: `describe-db-parameters --source system` が返す RDS system 由来の値。engine default と同じ意味ではない。

本書の「8.4既定値」は原則 engine default を指す。RDS の実効値は DB インスタンスクラスやRDS制御により異なり得るため、関連付け後に確認する。

## 1. 廃止済みパラメータのマッピング

| MySQL 8.0 のパラメータ | MySQL 8.4 の対応先 | マッピング | YAML の扱い | 状態 |
|---|---|---|---|---|
| `innodb_log_file_size` | `innodb_redo_log_capacity` | 直接換算しない | 設定対象外 | 保留 |
| `innodb_log_files_in_group` | `innodb_redo_log_capacity` | 直接換算しない | 設定対象外 | 保留 |

RDS for MySQL 8.4 のパラメータグループから `innodb_log_file_size` と `innodb_log_files_in_group` は削除され、redo ログ容量は `innodb_redo_log_capacity` が管理する。旧2値から新値への自動換算は行わない。8.4 では `innodb_dedicated_server` の有効化により redo ログ容量がインスタンスクラスに応じて自動算出されるため、旧設定を復元したい場合も、容量・書込み負荷・ストレージ空き容量を個別に評価して `innodb_redo_log_capacity` を明示する。

## 2. RDS for MySQL 8.4 の自動算出への移行

| 8.0 の設定 | 8.4 の設定 | マッピング | YAML の扱い |
|---|---|---|---|
| `innodb_dedicated_server` | 8.4で既定有効 | 8.0の明示値を自動コピーしない | `Source=user` があれば要レビュー |
| `innodb_buffer_pool_size` | `innodb_dedicated_server` によりメモリから算出 | 8.0のRDSメモリ式から8.4の分岐式へ | `Source=user` があれば要レビュー |
| `innodb_redo_log_capacity` | `innodb_dedicated_server` によりvCPUから算出 | 8.0の固定容量からvCPU式へ | `Source=user` があれば要レビュー |
| `innodb_purge_threads` | RDSでは `LEAST({DBInstanceVCPU/2},4)` が既定 | 固定値からvCPU依存へ | `Source=user` があれば要レビュー |

8.0のRDS既定の `innodb_buffer_pool_size` は物理メモリの75%を基準とし、ホスト用メモリ確保とチャンク単位の丸めにより実効値が調整される。8.4 では、`innodb_dedicated_server` が既定で有効になり、`innodb_buffer_pool_size` はメモリ量に応じて `< 1 GiB: 128 MiB`、`1〜4 GiB: 50%`、`> 4 GiB: 75%` の分岐式へ移行する。`innodb_redo_log_capacity` は、8.0.33以降のRDS既定 `2 GiB` から、8.4では `vCPU / 2 GiB`（最大16 GiB）の式へ移行する。小さいインスタンスクラスでは RDS が値を調整する場合もある。そのため、これらの値は単純な engine default でも `Source=system` そのものでもなく、インスタンス構成に依存する値として扱う。

## 3. 8.4 で既定が無効化された設定

次の表は MySQL Community 8.0 → 8.4 の engine default 差分である。RDS での変更可否・値は、対象リージョンの `mysql8.4` ファミリーを AWS CLI で取得して確認する。

| パラメータ | 8.0 engine default | 8.4 engine default | 移行方針 |
|---|---:|---:|---|
| `innodb_adaptive_hash_index` | `ON` | `OFF` | user 定義がなければ8.4既定を採用。`ON` を維持する場合はGreenで競合・性能を比較する。 |
| `innodb_change_buffering` | `all` | `none` | user 定義がなければ8.4既定を採用。`all` 等を移植する場合は、書込み性能だけでなくリカバリ・バルクロード・バッファプールリサイズへの影響を確認する。 |
| `innodb_buffer_pool_in_core_file` | `ON` | `OFF`（`MADV_DONTDUMP` 非対応時は `ON`） | user 定義がなければ8.4既定を採用。RDSで公開・変更可能かをCLIで確認する。 |

`innodb_change_buffering=none` は「変更バッファリングを使用しない」ことを表す。RDS の推奨事項も、MySQL 8.4 の既定を `none` とし、同値を推奨している。

## 4. 無効化ではないが既定値・算出方式が変わる設定

以下は MySQL 8.4 の engine default 差分であり、既存の `Source=user` 値をそのまま YAML へ反映する前に意図を確認する。`Source=user` がなければ、原則として8.4既定値を採用する。

| パラメータ | 8.0 engine default | 8.4 engine default | マッピング方針 |
|---|---:|---:|---|
| `innodb_buffer_pool_instances` | 1または8 | バッファプール・CPUから算出 | 固定値を自動コピーしない。 |
| `innodb_doublewrite_files` | `innodb_buffer_pool_instances * 2` | `2` | user 定義があれば書込み特性を確認する。 |
| `innodb_doublewrite_pages` | `innodb_write_io_threads` の値 | `128` | user 定義があれば書込み特性を確認する。 |
| `innodb_flush_method` | `fsync` | 対応環境では `O_DIRECT`、それ以外は `fsync` | RDSでの公開・変更可否を確認する。 |
| `innodb_io_capacity` | `200` | `10000` | ストレージIOPSと負荷試験で評価する。 |
| `innodb_io_capacity_max` | `MIN(2 * innodb_io_capacity, 2000)` | `2 * innodb_io_capacity` | `innodb_io_capacity` と一体で評価する。 |
| `innodb_log_buffer_size` | `16777216` | `67108864` | 大規模トランザクション・メモリ使用量を確認する。 |
| `innodb_numa_interleave` | `OFF` | `ON` | インスタンスクラスと性能影響を確認する。 |
| `innodb_page_cleaners` | `4` | `innodb_buffer_pool_instances` の値 | 固定値を自動コピーしない。 |
| `innodb_parallel_read_threads` | `4` | `MIN(number_of_cpus / 8, 4)` | CPU依存のため固定値を自動コピーしない。 |
| `innodb_purge_threads` | `4` | MySQL CommunityではCPU依存、RDSでは `LEAST({DBInstanceVCPU/2},4)` | RDSファミリー値を優先して確認する。 |
| `innodb_use_fdatasync` | `OFF` | `ON` | RDSでの公開・変更可否を確認する。 |

## 5. 稼働条件に応じたレビュー優先度

優先度は移行時に設定値を確定する順番であり、障害の重大度そのものではない。`P1` はインスタンスクラス、メモリ、ストレージ、書込み負荷により性能・容量・リカバリ時間へ大きく影響し得る項目、`P2` はワークロード特性により影響が変わる項目、`P3` は特定の実行環境で重点確認する項目である。

| 優先度 | パラメータ | 8.0→8.4 の主な変化種別 | 具体的な変化 | 値変化を採用した場合の主なリスク | 稼働条件に応じた確認事項 |
|---|---|---|---|---|---|
| P1 | `innodb_dedicated_server`<br>（専用サーバー向けInnoDB自動設定） | 自動算出になった | 既定: 無効 → 有効（RDS） | 明示していないバッファプール・redoログ容量まで変化し、メモリ・ストレージ使用量が変わる。 | 8.4で既定有効となり、後続のバッファプールとredoログ容量の自動算出を有効化する。 |
| P1 | `innodb_buffer_pool_size`<br>（バッファプール容量） | 自動算出になった | RDS 8.0: 物理メモリの75%を基準に丸め・予約 → 8.4: `<1 GiB:128 MiB`、`1〜4 GiB:50%`、`>4 GiB:75%` | 小さいクラスではキャッシュが減って読み取りI/O・レイテンシが増え、大き過ぎる明示値ではメモリ不足になる。 | DBインスタンスのメモリ量と接続・一時領域等のメモリ消費を踏まえて実効値を確認する。 |
| P1 | `innodb_redo_log_capacity`<br>（redoログ総容量） | 自動算出になった | RDS 8.0.33以降: `2 GiB` → 8.4: `vCPU / 2` GiB（最大16 GiB） | redoログ増大により必要ストレージと障害復旧時間が増え、縮小時は書込み性能が低下し得る。 | vCPU数、書込み量、リカバリ時間、必要ストレージ空き容量に直接影響する。 |
| P1 | `innodb_io_capacity`<br>（通常時のInnoDB I/O処理能力） | 設定値が変わった | `200` → `10000` | ストレージ性能を超えるフラッシュ要求により、I/O逼迫とクエリ遅延が起こり得る。 | プロビジョンドIOPSまたはストレージ性能と実際の書込み負荷に合わせて評価する。 |
| P1 | `innodb_io_capacity_max`<br>（最大時のInnoDB I/O処理能力） | 設定値が変わった | `MIN(2 * innodb_io_capacity, 2000)` → `2 * innodb_io_capacity` | チェックポイント時の瞬間I/Oが増え、他のI/Oやアプリケーション応答を圧迫し得る。 | `innodb_io_capacity` と組で、チェックポイント時に許容する最大I/O負荷を決める。 |
| P1 | `innodb_change_buffering`<br>（二次索引の変更バッファリング） | 設定値が変わった | `all` → `none` | 書込み主体のワークロードでは二次索引更新のI/O増加で性能が低下し得る。 | 書込み性能だけでなくリカバリ、バルクロード、バッファプールリサイズに影響する。 |
| P2 | `innodb_purge_threads`<br>（削除済み行のパージスレッド数） | 自動算出になった | `4` → RDSでは `LEAST({DBInstanceVCPU/2},4)` | 更新・削除が多い環境ではパージ不足による履歴リスト滞留、またはCPU使用率増加が起こり得る。 | vCPU数と更新・削除負荷により、履歴リストの解消速度とCPU使用率が変わる。 |
| P2 | `innodb_buffer_pool_instances`<br>（バッファプールの分割数） | 自動算出になった | 1または8 → バッファプールサイズ・CPU数から算出 | 分割数の変化によりラッチ競合、メモリ断片化、キャッシュ効率が変わり得る。 | バッファプールサイズとCPU数により、内部競合とメモリ分割のバランスが変わる。 |
| P2 | `innodb_parallel_read_threads`<br>（並列読み取りスレッド数） | 自動算出になった | `4` → `MIN(number_of_cpus / 8, 4)` | 並列スキャンが多い環境ではCPU競合または読取り性能低下が起こり得る。 | CPU数と並列スキャン・分析系クエリの比率により有効性が変わる。 |
| P2 | `innodb_page_cleaners`<br>（ダーティページのフラッシュスレッド数） | 自動算出になった | `4` → `innodb_buffer_pool_instances` の値 | 書込みピーク時のフラッシュ不足または過剰並列によるI/O競合が起こり得る。 | バッファプール構成と書込み負荷により、ページフラッシュの並列度が変わる。 |
| P2 | `innodb_adaptive_hash_index`<br>（適応ハッシュ索引の有効化） | 設定値が変わった | `ON` → `OFF` | ハッシュ索引の恩恵が大きい参照負荷では検索性能が低下し得る。 | 高並行な結合・参照負荷では有効性とラッチ競合の両方を確認する。 |
| P2 | `innodb_doublewrite_files`<br>（二重書込みファイル数） | 設定値が変わった | `innodb_buffer_pool_instances * 2` → `2` | 高書込み時の二重書込みI/O並列度が変わり、待機時間が増える可能性がある。 | 書込み負荷とストレージ性能に応じて、二重書込みの並列度とI/O影響を確認する。 |
| P2 | `innodb_doublewrite_pages`<br>（二重書込みバッファのページ数） | 設定値が変わった | `innodb_write_io_threads` の値 → `128` | 二重書込みバッファの挙動が変わり、書込みレイテンシが変動し得る。 | 書込み負荷とI/Oスレッド構成に応じて、二重書込みバッファのページ数を確認する。 |
| P2 | `innodb_flush_method`<br>（データファイルのフラッシュ方式） | 設定値が変わった | `fsync` → 対応環境では `O_DIRECT`、それ以外は `fsync` | OSページキャッシュ利用が変わり、I/Oレイテンシとメモリ使用量が変動し得る。 | RDSで変更可能な場合のみ、ストレージ・OS機能との組合せによるI/O挙動を確認する。 |
| P2 | `innodb_log_buffer_size`<br>（redoログバッファ容量） | 設定値が変わった | `16777216` → `67108864` | インスタンス当たりのメモリ使用量が増え、小メモリクラスでは余力を圧迫し得る。 | 大きいトランザクションやバッチ書込みの量に応じて、ログバッファ不足とメモリ消費を確認する。 |
| P3 | `innodb_numa_interleave`<br>（NUMAメモリのインターリーブ） | 設定値が変わった | `OFF` → `ON` | NUMA環境ではメモリアクセス局所性が変わり、特定負荷でレイテンシが悪化し得る。 | NUMA構成のインスタンスクラスでのみ、メモリ局所性とレイテンシへの影響を確認する。 |

### インスタンスタイプからの自動算出により実値が増減する項目

以下は、8.0で `Source=user` の明示設定がなく、8.0のRDS既定値と8.4の自動算出値を比較する場合の整理である。実効値はRDSの丸め・予約メモリ・`Source=system` により変わるため、最終確認は実機で行う。

**増える可能性がある項目**

- `innodb_redo_log_capacity`（redoログ総容量）: vCPUが4より大きい場合、8.0.33以降の既定 `2 GiB` から、8.4の `vCPU / 2 GiB`（最大16 GiB）へ増加する。
- `innodb_buffer_pool_instances`（バッファプールの分割数）: バッファプール容量とvCPU数が十分に大きく、8.4の算出式が8を超える場合、8.0の既定値8より増加する。
- `innodb_page_cleaners`（ダーティページのフラッシュスレッド数）: 8.4では `innodb_buffer_pool_instances` と同値になるため、同パラメータが増える構成では増加する。

**減る可能性がある項目**

- `innodb_buffer_pool_size`（バッファプール容量）: DBインスタンスメモリが1〜4 GiBの場合、8.0の約75%から8.4の50%へ減少する。
- `innodb_redo_log_capacity`（redoログ総容量）: vCPUが4未満の場合、8.0.33以降の既定 `2 GiB` から、8.4の `vCPU / 2 GiB` へ減少する。
- `innodb_purge_threads`（削除済み行のパージスレッド数）: vCPUが8未満の場合、8.0の既定4から8.4の `LEAST(vCPU / 2, 4)` へ減少する。
- `innodb_buffer_pool_instances`（バッファプールの分割数）: 8.4のバッファプール・vCPU算出式が8未満の場合、8.0の既定値8より減少する。
- `innodb_page_cleaners`（ダーティページのフラッシュスレッド数）: 8.4では `innodb_buffer_pool_instances` と同値になるため、同パラメータが減る構成では減少する。
- `innodb_parallel_read_threads`（並列読み取りスレッド数）: vCPUが32未満の場合、8.0の既定4から8.4の `MIN(vCPU / 8, 4)` へ減少する。

## 6. AWS CLI による確認

次の操作はすべて読み取り専用である。生成スクリプトの収集処理にも含まれる。

```bash
# 8.0 / 8.4 の engine default、変更可否、許容値を比較する
aws rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.0 \
  --output json

aws rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.4 \
  --output json

# 現行カスタムグループの明示設定とRDS system由来の値を分けて取得する
aws rds describe-db-parameters \
  --db-parameter-group-name <mysql80-parameter-group> \
  --source user \
  --output json

aws rds describe-db-parameters \
  --db-parameter-group-name <mysql80-parameter-group> \
  --source system \
  --output json
```

## 7. 現行変換ルールへの適用

現行の [mysql80-to-84-parameter-rules.yml](../config/mysql80-to-84-parameter-rules.yml) では、廃止済みの `innodb_log_file_size` と `innodb_log_files_in_group` を `omit` としており、redo ログ容量への自動変換は行わない。これは本書の「保留」と一致する。

生成スクリプトは、`omit` とした項目を除く `Source=user` 値を、8.4 に存在し変更可能であれば YAML へ明示する。本書の表を使って「8.4既定値を採用すべき」と判断した項目は、YAML を生成する前に `omit` ルールへ変更する。値を固定する場合は、Green 環境で性能・メモリ・ストレージ・リカバリ時間を確認する。

## 参考

- [AWS: RDS for MySQL 8.4 の機能差分](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.FeatureSupport.html)
- [AWS: MySQL 8.4 のバッファプールと redo ログ容量](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.MySQL.CommonDBATasks.Config.Size.8.4.html)
- [AWS: RDS for MySQL のメモリ・バッファプールに関するトラブルシューティング](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Troubleshooting.html)
- [AWS: RDS for MySQL のredoログ容量](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.MySQL.LogFileSize.html)
- [AWS: RDS の MySQL パラメータ一覧](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.MySQL.Parameters.html)
- [AWS: InnoDB Change Buffering の推奨](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USERRecommendationsManage.RecommendationReference.html)
- [MySQL 8.4: 8.0からの既定値変更一覧](https://dev.mysql.com/doc/refman/8.4/en/upgrading-from-previous-series.html)
