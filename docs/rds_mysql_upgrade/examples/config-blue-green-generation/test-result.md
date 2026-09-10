# Blue/Green 設定生成支援ツール: テスト結果

実行日: 2026-09-10

| 項目 | 結果 |
|---|---|
| 実 AWS API 呼び出し | 実施なし。ダミー `aws` コマンドが [rds-instance-inventory.test.json](rds-instance-inventory.test.json) を返却 |
| AWS CLI の組立確認 | PASS。`rds describe-db-instances` と `--region ap-northeast-1 --profile test-readonly` だけが渡されることを確認 |
| 収集リージョン | PASS。収集時の `--region ap-northeast-1` をインベントリ最上位の `aws_region` に保存し、生成設定へ引継ぎ |
| 生成環境 | `development`、`staging`、`production`（すべてダミー RDS ID） |
| 出力先 | `mktemp` で作成した一時ディレクトリ。既存の `config/blue-green/staging.deployment.yml`／`production.yml` は未変更 |
| 生成結果 | PASS。各 `blue-green.<environment>.expected.yml` と YAML データ構造として一致 |
| 承認状態 | PASS。`build`、`switchover`、`cleanup` はすべて `pending` |
| `mysql_verification` 既定値 | PASS。未指定時に `enabled: false` と `auth_method: parameter_store` を出力 |
| schema 定義 | PASS。二つの `databases.<schema>` が、各環境でそれぞれ異なる RDS ホストを参照 |

実行したテストは [test_generate_blue_green_config.sh](../../tests/test_generate_blue_green_config.sh) である。通常の実行環境では、事前に `python3 -m pip install 'PyYAML==6.0.2'` を行ってから次を実行する。

```bash
tests/test_generate_blue_green_config.sh
```
