# `python3 -c` 削減対応記録

> 位置づけ: **実施済みの変更の記録**である。[structure-review-proposal.md](structure-review-proposal.md) 論点1(実装言語の統一)で指摘した問題のうち、jq/yq を新規導入せずに対応できる範囲を先行して実施した。対象は `scripts/*.sh` に埋め込まれたインライン `python3 -c` のみで、Ruby／Go の実装統一(論点1本体)には未着手。

## 背景

`scripts/*.sh` には JSON抽出・検証・日時計算・設定ファイル読み込みなどをインライン `python3 -c` で行う箇所が38箇所あった。1行に複数の処理を詰め込む書き方(`(_ for _ in ()).throw(SystemExit(...))` によるassert代用など)で可読性が低く、単体テストもできない状態だった。

jq の新規導入は見送る方針のもと、**AWS CLI 自体が持つ `--query`(JMESPath)/`--output text`** と **GNU `date`/`printf` などの既存ツール**だけでどこまで削減できるかを検証し、実施した。

## 分類と対応方針

| 分類 | 内容 | 対応 |
|---|---|---|
| A | AWS CLI レスポンスからの単一/複数フィールド抽出・検証 | `aws ... --query --output text` に置き換え |
| B | 日時計算(CloudWatch のクエリ範囲など) | `date -u` コマンドに置き換え |
| C | YAML設定ファイル読み込み後の値抽出(`read_config`/`read_target` ラッパー) | YAML読み込みを1回のpython呼び出しに集約し、`shlex.quote()` で `KEY=VALUE` 行を出力、`eval` でbash変数に展開。中間JSONファイルと読み出し関数を全廃 |
| D | 固定キーの単純なJSON生成 | `printf` に置き換え |

## 結果: 38箇所 → 8箇所(約79%削減)

| ファイル | 対応前 | 対応後 | 残存理由 |
|---|---|---|---|
| `build_green.sh` | 4 | 1 | YAML読込(eval) |
| `collect_blue_green_prereqs.sh` | 5 | 0 | — |
| `collect_mysql84_parameter_inputs.sh` | 1 | 0 | — |
| `create_blue_green_deployment.sh` | 6 | 2 | YAML読込(eval) + `deployment_identifier`抽出(下記例外) |
| `switchover.sh` | 4 | 1 | YAML読込(eval) |
| `switchover_blue_green_deployment.sh` | 4 | 1 | YAML読込(eval) |
| `verify_green.sh` | 12 | 1 | YAML読込(eval) |
| `collect_green_runtime_values.sh` | 2 | 2 | 未着手(下記) |
| **合計** | **38** | **8** | |

## 実施内容の詳細

### A: `--query`/`--output text` への置き換え

読み取り専用(`describe-*`)のAPIは、アーカイブ用の `--output json > file` とは別に、抽出専用の `--query --output text` 呼び出しを追加する形にした。読み取り専用APIは呼び直しても副作用がないため、アーカイブと抽出を2回に分けても安全という判断。

```bash
# before
aws ... describe-db-instances --output json > source.json
source_arn=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["DBInstances"][0]["DBInstanceArn"])' source.json)

# after
aws ... describe-db-instances --output json > source.json
source_arn=$(aws ... describe-db-instances --query 'DBInstances[0].DBInstanceArn' --output text)
```

複数フィールドが必要な場合は JMESPath の multiselect(`[A,B,C]`)と bash の `read -r a b c <<< "$(...)"` を組み合わせて1呼び出しにまとめた(`verify_green.sh` のDeployment情報・Green構成取得など)。

**唯一の例外 — `create_blue_green_deployment.sh` の `deployment_identifier`**: `create-blue-green-deployment` は変更操作であり、抽出のために呼び直すと Blue/Green Deployment を二重作成してしまう。そのため保存済みレスポンスJSONを python で読む形を維持した。

### B: 日時計算 → `date` コマンド

```bash
# before
start_time=$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(hours=1)).isoformat().replace("+00:00", "Z"))')

# after
start_time=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
```

対象: `collect_blue_green_prereqs.sh`、`verify_green.sh`(計4箇所)。

⚠️ **GNU date 前提**(`-d` オプション)。本リポジトリの実行系(`mysql:8.4.8` = Debian、`aws-cli` 公式image、`Dockerfile.codebuild-runner` = `python:3.11-slim`)はいずれも GNU coreutils を含むため問題ないが、**macOSホストで直接シェルスクリプトを実行すると BSD date で `-d` が通らず壊れる**。全実行経路をDockerコンテナ経由に限定する運用が前提になる。

### C: YAML読み込みの呼び出し回数削減

各スクリプトのYAML読み込みを、`shlex.quote()` でエスケープした `KEY=VALUE` 行を出力する1回のpython呼び出しに変更し、`eval "$(...)"` でbash変数へ直接展開する形にした。

```bash
eval "$(python3 -c '
import shlex, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = d["services"][sys.argv[2]]
...
for k, v in values.items():
    print(f"{k}={shlex.quote(str(v))}")
' "$config" "$service")"
```

これにより `config.json`/`target.json` という中間ファイルと `read_config()`/`read_target()` ラッパー関数を全廃した。対象: `build_green.sh`、`create_blue_green_deployment.sh`、`switchover.sh`、`switchover_blue_green_deployment.sh`、`verify_green.sh`(5ファイル)。

中間JSONファイルの削除について: リポジトリ内のドキュメント(`upgrade-flow-steps.md` 等)を確認した限り、これらの中間ファイルを「証跡として残すべき成果物」と明記した記述はなかった。AWSの応答JSON(`source.json`、`deployment.json` など)はすべて従来どおり保存している。

### D: 単純なJSON生成 → `printf`

```bash
# before
python3 -c 'import json, sys; from datetime import datetime, timezone; print(json.dumps({"source_parameter_group": sys.argv[1], "collected_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")}))' "$source_pg" > metadata.json

# after
printf '{"source_parameter_group":"%s","collected_at":"%s"}\n' "$source_pg" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > metadata.json
```

対象: `collect_mysql84_parameter_inputs.sh`(1箇所)。`collect_blue_green_prereqs.sh` に既存の同型パターン(`printf` によるmetadata.json生成)があり、それに合わせた。`$source_pg` はAWSリソース識別子で文字種が限定されるため、エスケープなしの直接埋め込みでも安全と判断。

## 未着手・意図的に残したもの

| 箇所 | 理由 |
|---|---|
| YAML設定ファイル読み込み(6箇所、各スクリプト1回) | jq/yq非導入の方針の下では、bash単体でもjqでも代替不可能。python+PyYAMLの継続が必要 |
| `create_blue_green_deployment.sh` の `deployment_identifier` 抽出 | 変更操作(`create-blue-green-deployment`)のレスポンスであり、抽出のための再呼び出しがそのまま二重作成になるため |
| `collect_green_runtime_values.sh` のCFN YAML解析(23行目) | YAML解析のため上記と同じ理由で残存 |
| `collect_green_runtime_values.sh` のTSV→JSON変換(40行目) | MySQLシステム変数値は任意の文字列になりうるため、`printf` による手書きJSON化はエスケープが壊れるリスクがあり見送った |

## 検証状況

- 全ファイルで `bash -n` による構文チェックを実施し、エラーなし。
- `read_config`/`read_target` の参照漏れがないことを `grep` で確認済み。
- **実AWS環境での動作確認は未実施**(このセッションにAWS認証情報がないため)。特に `verify_green.sh` の以下は複雑なJMESPathフィルタ式を使っており、実環境での検証を推奨する。
  ```
  DBParameterGroups[?DBParameterGroupName=='${target_db_parameter_group_name}'] | [0].ParameterApplyStatus
  ```
- `--output text` は結果が0件/nullのとき文字列 `"None"` を返す(JSONの `null`/空配列とは異なる)。各所で `[[ "$val" != None ]]` の明示チェックを追加している。

## 変更したファイル

- `scripts/build_green.sh`
- `scripts/collect_blue_green_prereqs.sh`
- `scripts/collect_mysql84_parameter_inputs.sh`
- `scripts/create_blue_green_deployment.sh`
- `scripts/switchover.sh`
- `scripts/switchover_blue_green_deployment.sh`
- `scripts/verify_green.sh`

`scripts/collect_green_runtime_values.sh` は未変更(上記「未着手」参照)。

## 関連ドキュメント

- [structure-review-proposal.md](structure-review-proposal.md) — 論点1(実装言語の統一)。今回の対応はその中間ステップであり、Ruby/Go実装の統一自体は未着手。
