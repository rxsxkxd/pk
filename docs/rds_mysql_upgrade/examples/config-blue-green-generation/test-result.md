# Blue/Green 設定生成支援ツール: テスト結果

実行日: 2026-09-09

| 項目 | 結果 |
|---|---|
| 実 AWS API 呼び出し | 実施なし。ダミー `aws` コマンドが [rds-instance-inventory.test.json](rds-instance-inventory.test.json) を返却 |
| AWS CLI の組立確認 | PASS。`rds describe-db-instances` と `--region ap-northeast-1 --profile test-readonly` だけが渡されることを確認 |
| 生成環境 | `test` |
| 出力先 | `mktemp` で作成した一時ディレクトリ。既存の `config/blue-green/staging.yml`／`production.yml` は未変更 |
| 生成結果 | PASS。[blue-green.test.expected.yml](blue-green.test.expected.yml) と YAML データ構造として一致 |
| 承認状態 | PASS。`build`、`switchover`、`cleanup` はすべて `pending` |

実行したテストは [test_generate_blue_green_config.sh](../../tests/test_generate_blue_green_config.sh) である。通常の実行環境では、事前に `python3 -m pip install 'PyYAML==6.0.2'` を行ってから次を実行する。

```bash
tests/test_generate_blue_green_config.sh
```
