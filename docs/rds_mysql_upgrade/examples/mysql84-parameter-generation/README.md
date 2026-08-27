# MySQL 8.4 パラメータグループ生成サンプル

`scripts/collect_mysql84_parameter_inputs.sh` が取得する JSON 形式を模した、匿名化済みの入力データである。AWS への API 呼び出しは行わない。

`source-system-parameters.json` は `Source=system` の取得結果である。このサンプルでは空配列としているが、実運用の収集結果では RDS が決定する該当パラメータを格納する。`mysql80-default-parameters.json` と `mysql84-default-parameters.json` は、それぞれファミリーの **engine default** であり、`Source=system` とは別の値である。

`mysql84-default-parameters.json` は暫定のサンプル入力である。`mysql_native_password` と `authentication_policy` は、ともに MySQL 8.4 パラメータグループに存在し、変更可能である前提で記載している。実運用では必ず対象リージョンの `describe-engine-default-parameters --db-parameter-group-family mysql8.4` の収集結果を入力として使用する。

## 含めたケース

| 8.0 の `Source=user` 設定 | ルールによる扱い | 確認目的 |
|---|---|---|
| `binlog_format=MIXED` | `force` で `ROW` を生成 | Green 側の明示方針 |
| `log_slave_updates=1` | `log_replica_updates=1` へ `copy` | リネーム |
| `slave_parallel_workers=8` | `replica_parallel_workers=8` へ `copy` | リネーム |
| `innodb_log_file_size` | `omit` | 8.4 では `innodb_redo_log_capacity` を使用 |
| `default_authentication_plugin=mysql_native_password` | `mysql_native_password: ON` と `authentication_policy: "*:mysql_native_password"` を生成 | プラグインを有効化し、第1認証要素の既定を維持しつつ他方式も許可 |
| `max_allowed_packet` | 同名で `copy` | 未登録でも8.4で変更可能なら user 設定を反映 |

さらに、8.4 新規の `restrict_fk_on_non_standard_key` は `target_only` の「要レビュー」としてレポートに現れる。

## 再生成

リポジトリ直下で実行する。

```bash
ruby scripts/generate_mysql84_parameter_group.rb \
  --input-dir examples/mysql84-parameter-generation/input \
  --output-dir examples/mysql84-parameter-generation/output \
  --system sample \
  --environment production
```

このサンプルには「要レビュー」が 1 件残るため、コマンドは終了コード `1` を返す。ただしレビュー用の `output/mysql84-parameter-group.yaml` と `output/mysql80-to-mysql84-parameter-report.md` は生成される。実運用では、レビュー後にルールを追加・変更して「要レビュー」を 0 件にしてから CloudFormation へ適用する。
