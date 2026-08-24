# チュートリアル補足: 成立条件チェックの REVIEW の見方

> [チュートリアル](tutorial-migrate-one-db.md) のステップ 1（成立条件チェック）で `REVIEW` になった項目について、**何を確認すればよいか**と、**対応不要と判断してよい理由**を説明する。実際の DB（2026-10 時点）で `REVIEW` になった 3 項目を例にしている。チェック項目の一般的な説明は [phase-0-precheck.md](docs/phase-0-precheck.md)、アップグレードチェッカーの扱いは [移行ガイドの 0-3](docs/rds-mysql-84-migration-guide.md) にある。

## まとめ

| 項目 | 判断 | 必要な作業 |
|---|---|---|
| 0-1-02 binlog_format | **対応不要**（Blue `MIXED` / Green `ROW` は許容済み） | 下流で binlog を読むシステムが無いかを確認するだけ |
| 0-1-13 Amazon RDS Proxy | **対応不要の見込み**（この DB はどの Amazon RDS Proxy にも登録されていない） | アプリがこの DB に RDS Proxy 経由で接続していないこと、移行中に登録する予定が無いことを確認する。ProxySQL など自前のプロキシを使っている場合は、切替時の再接続を別途確認する |
| 0-3 アップグレードチェッカー Error 4 件 | **対応不要**（RDS for MySQL 8.4 では問題にならない） | Step 2 のパラメータ変換で認証方式が置き換わっていることを確認する |
| 0-3 Warning 19 件（既定値の変更・認証方式） | **許容**（性能面だけ Green で確認を推奨） | Green の検証レポートで実際の値を見る。書き込みが多い DB は負荷を比べる |
| 0-3 Notice 3 件（権限の削除） | **対応不要**（RDS が管理するアカウント） | DEFINER を別ユーザーにしたビュー・ストアドを作る運用があれば、Green で作れるか確認する |

アップグレードチェッカーは MySQL コミュニティ版の基準で判定する。RDS は自分で管理するパラメータ・アカウント・プラグインを移行時に調整するので、**チェッカーの Error がそのまま RDS での失敗を意味するわけではない。**そのため、成立条件チェックはチェッカーの結果をどのレベルでも `STOP` にせず、人の確認（`REVIEW`）に回している。実際に阻害する項目があれば、Blue/Green の作成時に RDS 自身の事前チェックで止まる。staging で Blue/Green を一度作れれば、最終的な確認になる。

---

## 0-1-02 binlog_format（`MIXED`）

```
REVIEW  0-1-02 binlog_format  MIXED（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断）。実効値=MIXED
```

### なぜ REVIEW か

値が `ROW` 以外のときは、移行とは別に「`ROW` に揃えるか」を判断する余地があるので、記録のために `REVIEW` にしている。**Blue/Green の作成を妨げるものではない。**

### 対応不要と判断してよい理由

**Blue が `MIXED`、Green が `ROW` の組み合わせは、動作上問題ないことを確認したうえで許容すると判断済みである**（[binlog-format-bluegreen-compatibility.md](docs/decisions/binlog-format-bluegreen-compatibility.md)）。Blue を事前に `ROW` へ変える必要はない。

- RDS for MySQL の Blue/Green が前提として求めているのは、自動バックアップ（バイナリログ）が有効なことで、`binlog_format=ROW` は必須ではない。
- Blue が `MIXED` のままでも、Green（8.4。8.4 用パラメータグループで `ROW`）はレプリケーションで Blue の変更を受け取って適用できる。レプリカは受け取ったイベントの形式を自分で判別するので、`MIXED` のイベントを拒否したり変換したりはしない。Green の `ROW` は、Green 自身が書き出す binlog の形式を決めるだけである。
- パラメータグループの値と実効値がどちらも `MIXED` で一致しているので、適用待ち（再起動待ち）や上書きも無い。

### 確認すること

- **下流で binlog を読むシステムが無いか**（AWS DMS、Debezium などの CDC、独自の ETL）。こうしたシステムは `ROW` を前提にしていることが多い。今 `MIXED` で動いているなら移行で悪化することはないが、切替後に Green の形式（8.4 用パラメータグループの値）が変わると、出力される形式も変わる。
- `binlog_format` は MySQL 8.0.34 から非推奨だが、8.4 でも使える。将来 `ROW` に揃える場合は、移行と切り離した変更として扱う。

---

## 0-1-13 Amazon RDS Proxy

```
REVIEW  0-1-13 RDS Proxy  Proxy=test-proxy, proxy-quick-park-db。対象 Blue の登録なし
```

（この結果を出した後に、表示を `0-1-13 Amazon RDS Proxy  Amazon RDS Proxy=…。対象 Blue はどの RDS Proxy のターゲットにも未登録` に改めた。内容は同じである。）

**この項目が扱うのは AWS のマネージドサービス Amazon RDS Proxy だけである。**AWS の API（`describe-db-proxies` / `describe-db-proxy-targets`）で調べているので、ProxySQL・HAProxy などを自前で動かしているプロキシや、アプリ側の接続プールは対象外で、検出もしない（それらの確認は下の「Amazon RDS Proxy 以外のプロキシを使っている場合」）。

### なぜ REVIEW か

リージョン内に Amazon RDS Proxy が存在するが、移行する DB（Blue）はどの RDS Proxy のターゲットにも登録されていない、という状態である。ツールは「この DB を RDS Proxy 経由で使う予定があるか」を知ることができないので、人に判断を求めている。

これが問題になりうるのは、**Blue/Green Deployment を作った後は、その DB を Amazon RDS Proxy に新しく登録できない**という制約があるためである。RDS Proxy 経由で使いたい DB は、Blue/Green を作る前に登録しておく必要がある。

### 確認すること

1. **アプリケーションがこの DB に RDS Proxy 経由で接続していないこと。**アプリの接続先が DB のエンドポイント（`<db名>.xxxx.<region>.rds.amazonaws.com`）であり、RDS Proxy のエンドポイント（`<proxy名>.proxy-xxxx.<region>.rds.amazonaws.com`）ではないことを確かめる。
2. **2 つの RDS Proxy が別の DB 用であること。**収集結果の `db-proxy-targets-*.json` の `RdsResourceId` / `Endpoint` を見ると、各 RDS Proxy がどの DB を対象にしているかが分かる。名前からは、`test-proxy` は検証用、`proxy-quick-park-db` は別システムの DB 用と推測できるが、実際の登録先で確かめる。
3. **移行の間（Blue/Green を作ってから削除するまで）に、この DB を RDS Proxy に登録する予定が無いこと。**

3 つとも当てはまれば、Amazon RDS Proxy はこの移行に関係しないので、対応は不要である。この DB を RDS Proxy 経由にしたい場合は、Blue/Green を作る前に登録するか、移行が終わって Blue/Green を削除してから登録する。

### Amazon RDS Proxy 以外のプロキシを使っている場合（別途確認が要る事項）

この DB の前に ProxySQL・HAProxy・MySQL Router などを自前で置いている場合や、アプリ側で接続プールを持っている場合は、成立条件チェックの結果とは別に、切替（Switchover）のときの挙動を確かめる。

- **接続先の名前は変わらない。**切替では Green が元の DB の名前（エンドポイント）を引き継ぐので、ミドルウェアの設定でホスト名を指定していれば、設定を書き換える必要はない。
- **張りっぱなしの接続と DNS のキャッシュに注意する。**切替の時点で、旧 Blue への既存の接続は切断される。ミドルウェアが自動で再接続し、そのときに DNS を引き直して新しい接続先（Green）へつながるかが重要である。DNS の結果を長くキャッシュするもの（JVM の DNS キャッシュなど）や、IP アドレスを固定で指定した設定は、旧 Blue（名前の末尾に `-old1` が付いたもの）へつなぎ続けたり、つながらなくなったりするおそれがある。
- **確かめ方**: staging で切替を一度行い、ミドルウェアを通したアプリが、切替後に新しい DB（8.4）へつながることを確かめるのが確実である。

---

## 0-3 アップグレードチェッカー

```
REVIEW  0-3 アップグレードチェッカー  Error=4 / Warning=19 / Notice=3（target=8.4.9）
```

### Error: 削除されるシステム変数（`removedSysVars`）

| 変数 | 現在値 |
|---|---|
| `master_info_repository` | `TABLE` |
| `relay_log_info_repository` | `TABLE` |
| `relay_log_info_file` | `relay-log.info` |

**対応不要と判断してよい理由**

- この 3 つは、レプリケーションの位置情報（どこまで受け取り・適用したか）を「テーブルに保存するか、ファイルに保存するか」を決める変数である。MySQL 8.0.23 で非推奨になり、8.4 で削除された。**8.4 ではテーブルに保存する方式しか無い。**
- 現在値はどちらも `TABLE`（テーブルに保存）なので、8.4 の唯一の動作と同じである。変数が無くなっても、振る舞いは何も変わらない。`relay_log_info_file` は、ファイルに保存する方式のときだけ使うファイル名で、`TABLE` では使われていない。
- チェッカーは「値が設定されている（GLOBAL に存在する）」ことを検出しているだけで、利用者が設定を変えたことを意味しない。RDS の既定値である。
- Green は 8.4 用のパラメータグループで作られ、そこにはこの 3 つが存在しないので、起動時に問題になることもない。

**確認すること**: 8.0 のパラメータグループで、この 3 つを利用者が明示的に設定していない（`Source` が `user` でない）こと。明示設定があっても、Step 2 のパラメータ変換で 8.4 側へは持ち込まれない。

### Error: 既定の認証方式（`deprecatedDefaultAuth`）

| 変数 | 現在値 |
|---|---|
| `default_authentication_plugin` | `mysql_native_password` |

**対応不要と判断してよい理由**

- MySQL コミュニティ版 8.4 では、`default_authentication_plugin` が削除され、`mysql_native_password` の認証方式も既定で無効になる。そのため、チェッカーは「8.4 へ上げる前に直す必要がある」と判定している。
- **RDS for MySQL 8.4 では、`mysql_native_password` は引き続き使える。**既定の認証方式は `authentication_policy` で決める仕組みに変わった。
- このリポジトリの Step 2 のパラメータ変換は、8.0 で `default_authentication_plugin=mysql_native_password` を明示している場合に、8.4 用パラメータグループへ `authentication_policy="*:mysql_native_password"` と `mysql_native_password=ON` を設定する（`config/mysql80-to-84-parameter-rules.yml`）。これで、既存ユーザーも、新しく作るユーザーも、今と同じ認証方式で動く。

**確認すること**

- Step 2 の変換レポートと、Green の検証レポートで、`authentication_policy` と `mysql_native_password` が上のとおりになっていること。
- Green で、既存のアプリ用ユーザーで接続できること（切替前の確認）。
- `mysql_native_password` は将来のメジャーバージョンで廃止される予定である。今回の移行とは別に、`caching_sha2_password` への切り替えを中期的に計画しておく。

### Warning: 既定値が変わるシステム変数（`sysVarsNewDefaults`）

**全体として許容してよい理由**

- これらは「パラメータグループで値を明示していない変数は、8.4 では新しい既定値になる」という**お知らせ**であり、移行を妨げるものではない。
- 新しい既定値は、MySQL が近年のハードウェア（SSD、多コア）に合わせて見直したもので、多くの環境で同等か改善になる。このリポジトリでも「利用者が明示設定していない変数は 8.4 の既定値を採用する」方針にしている（[innodb-mysql80-to-84-parameter-mapping.md](docs/references/innodb-mysql80-to-84-parameter-mapping.md)）。
- 実際の値は、RDS の 8.4 用の既定と、Step 2 で作ったパラメータグループで決まる。Green の検証レポートで、実際に適用された値を確認できる。

**変数ごとの説明**（「現在値」は Blue の値）

| 変数 | 変化 | 現在値 | 影響と判断 |
|---|---|---|---|
| `binlog_transaction_dependency_tracking` | `COMMIT_ORDER` → `WRITESET` | `COMMIT_ORDER` | レプリカで並列に適用できるかの判定方法。`WRITESET` の方がレプリカの並列度が上がる。8.4 では変数自体が無くなり常に `WRITESET` になる。悪影響は無い |
| `group_replication_consistency` | `EVENTUAL` → `BEFORE_ON_PRIMARY_FAILOVER` | `EVENTUAL` | グループレプリケーションの設定。この DB はグループレプリケーションを使っていないので関係しない |
| `group_replication_exit_state_action` | `READ_ONLY` → `OFFLINE_MODE` | （変数なし） | 同上。プラグインが読み込まれていないので変数自体が無い |
| `innodb_adaptive_hash_index` | `ON` → `OFF` | `ON` | よく使う索引の検索を速めるための内部キャッシュ。同じ行を繰り返し読む処理が多い DB では、`OFF` で読み込みが少し遅くなることがある。一方で、同時実行が多いと競合の原因にもなるため、8.4 では既定で無効になった。**性能を気にする DB は Green で比べる** |
| `innodb_buffer_pool_in_core_file` | `ON` → `OFF` | `ON` | MySQL が異常終了したときのダンプ（core ファイル）に、バッファプールの中身を含めるか。RDS では利用者が core ファイルを扱わないので関係しない |
| `innodb_buffer_pool_instances` | 8（1 GB 未満なら 1）→ vCPU 数 / 4（最低 1） | `1` | バッファプールの分割数。小さいインスタンスでは 8.4 でも 1 か少数になり、ほぼ変わらない |
| `innodb_change_buffering` | `all` → `none` | `all` | 二次索引の更新をまとめて書くための仕組み。SSD では効果が小さく、RDS も `none` を推奨している。**二次索引の多いテーブルへ大量に書き込む DB は、Green で書き込み性能を比べる** |
| `innodb_doublewrite_files` | バッファプールの分割数 × 2 → 2 | `2` | 書き込みの安全性を保つためのファイル数。現在値と同じなので変わらない |
| `innodb_io_capacity` | 200 → 10000 | `200` | バックグラウンドの書き込み（ダーティページのフラッシュ）にどれだけ I/O を使ってよいか。**8.4 の既定は高いので、ストレージの IOPS が小さい（小さい gp2 など）と、I/O を使い切って応答が遅くなることがある。**Green で実際の値を確認し、ストレージの IOPS に見合っているかを見る |
| `innodb_io_capacity_max` | 200（実際は 2000）→ `innodb_io_capacity` × 2 | `2000` | 上の最大値。上と一緒に判断する |
| `innodb_log_writer_threads` | `ON` → `OFF`（vCPU が 32 以下のとき） | `ON` | REDO ログ専用の書き込みスレッド。少ない vCPU では専用スレッドがかえって負担になるため、8.4 では小さいインスタンスで無効になる。悪影響は無い |
| `innodb_numa_interleave` | `OFF` → `ON` | `OFF` | 複数の CPU ソケットがあるサーバーでのメモリの割り当て方。RDS の一般的なインスタンスでは影響しない |
| `innodb_page_cleaners` | 4 → バッファプールの分割数 | `1` | ダーティページを書き出すスレッド数。現在値 1 は、分割数 1 と同じなので変わらない |
| `innodb_parallel_read_threads` | 4 → vCPU 数 / 8（最低 4） | `4` | 並列読み込みのスレッド数。vCPU が 32 以下なら 4 のままで変わらない |
| `innodb_read_io_threads` | 4 → vCPU 数 / 2（最低 4） | `4` | 読み込み I/O のスレッド数。vCPU が 8 以下なら 4 のままで、多ければ増える。悪影響は無い |

**確認すること**

- Green の検証レポートで、上の変数の実際の値を見る。特に `innodb_io_capacity` / `innodb_io_capacity_max` が、ストレージの性能に見合っているか。
- 書き込みが多い DB、性能の要件が厳しい DB は、Green に本番相当の負荷をかけて、`innodb_adaptive_hash_index` と `innodb_change_buffering` の影響を比べる。今の値を保ちたい変数は、Step 2 のパラメータグループに明示する。

### Warning: 非推奨の認証方式を使うユーザー（`authMethodUsage`）

| ユーザー | 内容 |
|---|---|
| `rds_superuser_role@%` | `mysql_native_password` を使っている |
| `rdsrepladmin@%` | 同上 |

**対応不要と判断してよい理由**

- どちらも **RDS が管理する内部のアカウント**である（`rds_superuser_role` はマスターユーザーに権限を与えるためのロール、`rdsrepladmin` は RDS がレプリケーションに使うアカウント）。利用者は変更しない。変更すると RDS の管理機能に影響するおそれがある。
- RDS for MySQL 8.4 では `mysql_native_password` が使えるので、これらのアカウントはそのまま動く。
- **アプリ用のユーザーは検出されていない。**つまり、アプリ用のユーザーはすでに `caching_sha2_password` などの方式を使っており、8.4 の認証方式の変更の影響を受けない。

### Notice: 削除される権限（`invalidPrivileges`）

| ユーザー | 削除される権限 |
|---|---|
| `'rds_superuser_role'@'%'` | `SET_USER_ID` |
| `'rdsadmin'@'localhost'` | `SET_USER_ID` |

**対応不要と判断してよい理由**

- `SET_USER_ID` は、ビューやストアドプロシージャの `DEFINER` に自分以外のユーザーを指定するための権限である。MySQL 8.2 で非推奨になり、8.4 では削除された。代わりに `SET_ANY_DEFINER`（任意の DEFINER を指定できる）と `ALLOW_NONEXISTENT_DEFINER`（存在しないユーザーを DEFINER にできる）に分かれた。
- 検出されたのはどちらも **RDS が管理するアカウント**で、8.4 での権限は RDS が整える。利用者が付け替える必要は無い。
- レベルも Notice（情報）で、アップグレード自体には影響しない。

**確認すること**: アプリや運用で、`DEFINER` に別のユーザーを指定したビュー・ストアドプロシージャ・トリガーを作ることがある場合は、Green でマスターユーザーから作成できるかを一度確かめる。既に存在するビュー・ストアドは、そのまま移行される。

---

## 参考

- [移行ガイド 0-3（アップグレードチェッカー）](docs/rds-mysql-84-migration-guide.md) — チェッカーの結果を人が確認する方針と、Error になりやすい項目の対処表
- [phase-0-precheck.md](docs/phase-0-precheck.md) — 0-1-01〜14 のチェック項目
- [binlog-format-bluegreen-compatibility.md](docs/decisions/binlog-format-bluegreen-compatibility.md) — Blue `MIXED` → Green `ROW` の互換性
- [innodb-mysql80-to-84-parameter-mapping.md](docs/references/innodb-mysql80-to-84-parameter-mapping.md) — InnoDB パラメータの 8.0 → 8.4 の対応と、変更による影響
- `config/mysql80-to-84-parameter-rules.yml` — Step 2 のパラメータ変換ルール（認証方式の置き換えを含む）
