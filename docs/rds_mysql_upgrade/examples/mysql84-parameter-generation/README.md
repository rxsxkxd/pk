# MySQL 8.4 パラメータグループ生成サンプル

`scripts/collect_mysql84_parameter_inputs.sh` が取得する JSON 形式を模した、匿名化済みの入力データである。AWS への API 呼び出しは行わない。

`source-system-parameters.json` は `Source=system` の取得結果である。このサンプルでは空配列としているが、実運用の収集結果では RDS が決定する該当パラメータを格納する。`mysql80-default-parameters.json` と `mysql84-default-parameters.json` は、それぞれファミリーの **engine default** であり、`Source=system` とは別の値である。

## 含めたケース

| 8.0 の `Source=user` 設定 | ルールによる扱い | 確認目的 |
|---|---|---|
| `binlog_format=MIXED` | `force` で `ROW` を生成 | Green 側の明示方針 |
| `log_slave_updates=1` | `log_replica_updates=1` へ `copy` | リネーム |
| `slave_parallel_workers=8` | `replica_parallel_workers=8` へ `copy` | リネーム |
| `innodb_log_file_size` | `omit` | 8.4 では `innodb_redo_log_capacity` を使用 |
| `default_authentication_plugin` | `review` | `authentication_policy` へ自動変換しない |
| `max_allowed_packet` | `review` | 未登録の user 設定を無条件にコピーしない |

さらに、8.4 新規の `restrict_fk_on_non_standard_key` は `target_only` の `review` としてレポートに現れる。

## 再生成

リポジトリ直下で実行する。

```bash
ruby scripts/generate_mysql84_parameter_group.rb \
  --input-dir examples/mysql84-parameter-generation/input \
  --output-dir examples/mysql84-parameter-generation/output \
  --system sample \
  --environment production
```

このサンプルには「要レビュー」が 3 件残るため、コマンドは終了コード `1` を返す。ただしレビュー用の `output/mysql84-parameter-group.yaml` と `output/mysql80-to-mysql84-parameter-report.md` は生成される。実運用では、レビュー後にルールを追加・変更して「要レビュー」を 0 件にしてから CloudFormation へ適用する。
