# Blue/Green 設定生成支援ツール: テスト結果

実行日: 2026-09-10

| 項目 | 結果 |
|---|---|
| 実 AWS API 呼び出し | 実施なし。ダミー `aws` コマンドが [rds-instance-inventory.test.json](rds-instance-inventory.test.json) を返却 |
| AWS CLI の組立確認 | PASS。`rds describe-db-instances` と、パラメータグループごとの `rds describe-db-parameters` だけが `--region ap-northeast-1 --profile test-readonly` 付きで渡されることを確認（各グループちょうど 1 回） |
| 収集リージョン | PASS。収集時の `--region ap-northeast-1` をインベントリ最上位の `aws_region` に保存し、生成設定へ引継ぎ |
| 生成環境 | `development`、`staging`、`production`（すべてダミー RDS ID） |
| 出力先 | `mktemp` で作成した一時ディレクトリ。既存の `config/blue-green/{staging,production}.deployment.yml` は未変更 |
| 生成結果 | PASS。各 `blue-green.<environment>.expected.yml` と YAML データ構造として一致 |
| 承認状態 | PASS。`build`、`switchover`、`cleanup` はすべて `pending` |
| `mysql_verification` の継承 | PASS。ルート既定値を接続配下がキー単位で上書き（production の audit だけ別パラメータ・別ポート） |
| `source_time_zone` | PASS。Blue のパラメータグループの `time_zone` 実値（`user` / `engine-default` の両ケース）を確認用に出力 |
| 生成単位 | PASS。同じ `rds_instance` を指す接続を 1 deployment へまとめ、`schemas` を集約（development は 2 接続 → 1 deployment） |
| レビュー用レポート | PASS。別コマンド `generate_blue_green_config_report` の出力が各 `blue-green.<environment>.report.expected.md` と一致。設定ファイルは書き換えない |

ロジックの単体テストは `scripts/internal/{common,collect,generate}` にあり、`cd scripts && go test ./...` で実行する。下の結果はコマンドを通した E2E テスト [test_generate_blue_green_config.sh](../../tests/test_generate_blue_green_config.sh) のものである。収集・生成はどちらも Go なので、Go があれば次だけで実行できる。

```bash
tests/test_generate_blue_green_config.sh
```
