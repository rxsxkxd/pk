# Step 1 成立条件チェックの入出力サンプル

`tools/evaluate_blue_green_prereqs.rb` の**匿名化済みゴールデンファイル**である。AWS へは接続しない。

| ディレクトリ | 内容 |
|---|---|
| `input/` | `tools/collect_blue_green_prereqs.sh` が出力する JSON を模したもの |
| `output/` | 生成されるレポート（`prereqs-evaluation-report.md`） |

## 再生成

```bash
ruby tools/evaluate_blue_green_prereqs.rb \
  --input-dir examples/blue-green-prereqs/input \
  --output examples/blue-green-prereqs/output/prereqs-evaluation-report.md
```

このサンプルは STOP が 0 件・REVIEW が 2 件なので、**終了コードは 0** である。

## 何を固定しているか

このサンプルは**ゲート①（移行できるか・どれを対象にするか）の判断材料**がレポートに載ることを示す。判定そのものだけでなく、**観測値と取得元**が残ることが要点である。

| 判定 | 項目 | 観測値 | 取得元 |
|---|---|---|---|
| PASS | 0-1-01 自動バックアップ | `BackupRetentionPeriod=7` | `db-instance.json` |
| REVIEW | 0-1-02 binlog_format | `MIXED` | `db-parameters.json` |
| REVIEW | 0-1-06 外部 binlog レプリカ | AWS CLI では判定不可 | 手動確認 |

`binlog_format` を `MIXED` にしてあるのは、**REVIEW が出る経路を固定する**ためである（`ROW` だと PASS になり REVIEW 節が消える）。Blue が `MIXED` でも Blue/Green の作成自体は妨げられない——背景は [binlog-format-bluegreen-compatibility.md](../../docs/decisions/binlog-format-bluegreen-compatibility.md) にある。

## テスト

`tests/evaluate_blue_green_prereqs_test.sh` がこの入出力を使う。確認するのは次の 4 点である。

- `--output` を省略しても従来どおり動く（ファイルを作らず、標準出力の書式も変わらない）
- `--output` でレポートを出せ、**ゴールデンと一致する**
- STOP があれば終了コード 1 になり、レポートに STOP 節が出る
- 観測値と取得元がレポートに載る

**判定ロジックを変えたら再生成して差分をレビューする。**
