# CloudFormation 短縮記法の検証用 fixture

Step 2 が生成する DB パラメータグループのテンプレートは**長形式**（`Ref: Xxx`）で出力されるが、Step 2 のレビューで人が CFn 慣用の**短縮記法**（`!Ref` / `!Sub`）へ書き換えることがある。

テンプレートの読み取りは `internal/cfn` が担う。レポート生成器（`generate_green_verification_report.go`。パラメータ名の列挙 `--list-parameter-names` を含む）が `scripts/internal/cfn` を、レビューレポート生成（`tools/generate_blue_green_config_report`）が `tools/internal/cfn` を使う。**この 2 本は同一内容の複製で、`tests/cfn_shorthand_test.sh` が一致を検査する。**

以前は読み取り実装が 3 つに分かれており、いずれも短縮記法を正しく扱えなかった。

| 当時の実装 | 当時の挙動 |
|---|---|
| `collect_green_runtime_values.sh`（Python / `yaml.safe_load`） | **即座に失敗**（`could not determine a constructor for the tag '!Ref'`） |
| `generate_green_verification_report.rb`（Ruby / Psych） | **黙って通るが、タグを捨てて引数の文字列だけを残す** |
| `generate_green_verification_report.go`（Go / yaml.v3。自前実装） | 同上 |

Ruby / Go は `replica_parallel_workers: !Ref Workers` を `"Workers"` という値として読み、RDS の実値と比較して**存在しないドリフトを報告**していた。

## 現在の挙動

3 実装とも**短縮記法を長形式へ正規化**して読む。

| 記法 | 正規化後 |
|---|---|
| `!Ref X` | `{"Ref": "X"}` |
| `!Sub 'y'` | `{"Fn::Sub": "y"}` |
| `!GetAtt [a, b]` | `{"Fn::GetAtt": ["a", "b"]}` |

値が組み込み関数の項目は、CloudFormation のパラメータ解決なしには実値が決まらない。したがって**比較対象から外し、「比較不能」としてレポートに明示**する。ドリフト判定にも含めない。

パラメータ**名**は取得できるため、MySQL 実効値の収集対象にはなる。

## ファイル

| ファイル | 用途 |
|---|---|
| `mysql84-parameter-group-shorthand.yaml` | `!Ref` / `!Sub` を含むテンプレート。解決可能な値と組み込み関数の両方を持つ |
| `collected/*.json` | レポート生成器へ渡す最小の収集済み JSON（AWS API の応答を模したもの） |

## 実行

```bash
tests/cfn_shorthand_test.sh
```

3 実装が同じ解釈をすることを確認する。AWS へは接続しない。Ruby / Go が未導入の環境では該当実装をスキップする。Go のレポート生成器は `scripts/` 直下の `package main` なので、一時ディレクトリへ `go.mod`・`go.sum` とソースを写して単体ビルドする。
