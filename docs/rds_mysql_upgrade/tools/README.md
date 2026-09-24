# tools/ — 人が手で実行するツール

`tools/` には**人が手で実行するもの**だけを置く（CI から到達するものは `scripts/`）。本書は全ツールの索引で、各ツールの用途・入出力・主なオプション・終了コードをまとめる。**背景や判定の中身は詳細ドキュメントに書き、ここからはリンクするだけにする。**

実行順に並べた手順は [operations-migration-run.md](../operations-migration-run.md) にある。本書は「このツールは何をして、何を渡して、何が返るか」を引くためのものである。

**コマンドはすべてリポジトリのルートで実行する。**オプションの完全な一覧は各ツールの `--help` が正である。

## 一覧

| Step | ツール | 言語 | AWS | 用途 | ゲート |
|---|---|---|---|---|---|
| 1 | [`collect_blue_green_prereqs.sh`](#collect_blue_green_prereqssh) | Bash | 読み取りのみ | Blue/Green の成立条件に要る情報を収集 | — |
| 1 | [`evaluate_blue_green_prereqs.rb`](#evaluate_blue_green_prereqsrb) | Ruby | 呼ばない | 収集結果を判定し、レポートを出す | ① |
| 2 | [`collect_mysql84_parameter_inputs.sh`](#collect_mysql84_parameter_inputssh) | Bash | 読み取りのみ | 8.0 パラメータグループと既定値を収集 | — |
| 2 | [`generate_mysql84_parameter_group.rb`](#generate_mysql84_parameter_grouprb) | Ruby | 呼ばない | 8.4 用 CloudFormation テンプレートとレポートを生成 | ① |
| 3 前 | [`collect_rds_instance_inventory`](#collect_rds_instance_inventory) | Go | 読み取りのみ | RDS インベントリを収集 | — |
| 3 前 | [`generate_blue_green_config`](#generate_blue_green_config) | Go | 呼ばない | 移行設定 YAML を生成 | — |
| 3 前 | [`generate_blue_green_config_report`](#generate_blue_green_config_report) | Go | 呼ばない | 移行設定のレビューレポートを生成 | ② |
| 7 | [`cleanup.sh`](#cleanupsh) | Bash | **変更あり（削除）** | Blue/Green Deployment と旧 Blue の削除 | — |

どのツールも「収集」と「判定・生成」が別コマンドになっている。収集は AWS の読み取り API だけを呼んで JSON を落とし、判定・生成は AWS を呼ばずにその JSON だけを読む。**AWS を変更するのは `cleanup.sh` だけである。**

終了コードの共通の意味:

| 終了コード | 意味 |
|---|---|
| `0` | 成功（判定系では「不適合なし」） |
| `1` | 判定系では不適合あり。収集系では AWS CLI・入力の失敗 |
| `2` | 使い方の誤り（引数不足・不明な引数）。Go の 3 本と `cleanup.sh` |

ゲート①〜③の意味とレポートの生成元は [report-generation-flows.md](../report-generation-flows.md) にある。

---

## Step 1: 成立条件チェック

### `collect_blue_green_prereqs.sh`

対象 Blue について、Blue/Green Deployments の成立条件に要る情報を AWS の読み取り API（`Describe*` / `Get*`）で集める。

```bash
tools/collect_blue_green_prereqs.sh \
  --db-instance-id <blue-id> --region <region> --profile <profile> \
  --output-dir <収集先>
```

| オプション | 必須 | 既定値 | 内容 |
|---|---|---|---|
| `--db-instance-id ID` | ○ | — | 対象 Blue の DB インスタンス識別子 |
| `--region` / `--profile` | | AWS CLI の設定 | |
| `--target-engine-version V` | | `8.4.9` | 移行先バージョン（利用可能なインスタンスクラスの確認に使う） |
| `--output-dir DIR` | | 一時ディレクトリ | 収集した JSON の保存先 |

- **出力**: `db-instance.json`、`all-db-instances.json`、`db-parameters.json`、`option-group.json`、`orderable-classes.json`、`db-proxies.json`、`db-proxy-targets-<n>.json`、`integrations.json`、`free-storage-space.json`、`metadata.json`。最後に保存先を表示する
- **終了コード**: `0` 収集完了 / `0` 以外 AWS CLI の失敗
- **詳細**: 各取得処理を 1 つずつ手で実行する手順は [collect_blue_green_prereqs.md](collect_blue_green_prereqs.md)。チェック項目の背景は [phase-0-precheck.md](../docs/phase-0-precheck.md)

### `evaluate_blue_green_prereqs.rb`

上の収集結果を判定し、`OK` / `REVIEW` / `STOP` を出す。AWS は呼ばない。

```bash
ruby tools/evaluate_blue_green_prereqs.rb \
  --input-dir <収集先> --output <収集先>/prereqs-evaluation-report.md
```

| オプション | 必須 | 内容 |
|---|---|---|
| `--input-dir DIR` | ○ | `collect_blue_green_prereqs.sh` の出力先 |
| `--output FILE` | | Markdown レポートの出力先（省略時は標準出力の一覧だけ） |

- **出力**: 標準出力に判定一覧。`--output` を付けると**ゲート①のレポート**（判定に加えて観測値と取得元）
- **終了コード**: `0` `STOP` なし / `1` `STOP` が 1 件以上。`REVIEW` は終了コードに影響しない（人が確認する）
- **詳細**: [report-generation-flows.md](../report-generation-flows.md)、サンプルは [examples/blue-green-prereqs/](../examples/blue-green-prereqs/README.md)

---

## Step 2: パラメータグループ

### `collect_mysql84_parameter_inputs.sh`

移行元の 8.0 カスタムパラメータグループと、8.0 / 8.4 の既定値を集める。

```bash
tools/collect_mysql84_parameter_inputs.sh \
  --source-parameter-group <8.0-pg-name> --output-dir <収集先>
```

| オプション | 必須 | 既定値 | 内容 |
|---|---|---|---|
| `--source-parameter-group NAME` | ○ | — | 既存の MySQL 8.0 カスタムパラメータグループ |
| `--db-instance-id ID` | | — | 指定するとそのインスタンスへの関連付けと適用状態も取る |
| `--region` / `--profile` | | AWS CLI の設定 | |
| `--output-dir DIR` | | 一時ディレクトリ | 収集した JSON の保存先 |

- **出力**: `source-parameter-group.json`、`source-user-parameters.json`、`source-system-parameters.json`、`mysql80-default-parameters.json`、`mysql84-default-parameters.json`、`metadata.json`（`--db-instance-id` 指定時は `source-db-instance.json` も）
- **終了コード**: `0` 収集完了 / `0` 以外 AWS CLI の失敗

### `generate_mysql84_parameter_group.rb`

収集結果と変換ルールから、8.4 用パラメータグループの CloudFormation テンプレートとレポートを作る。AWS は呼ばない。

```bash
ruby tools/generate_mysql84_parameter_group.rb \
  --input-dir <収集先> --output-dir <生成先> --system <name> --environment <env>
```

| オプション | 必須 | 既定値 | 内容 |
|---|---|---|---|
| `--input-dir DIR` | ○ | — | `collect_mysql84_parameter_inputs.sh` の出力先 |
| `--output-dir DIR` | ○ | — | 生成先 |
| `--system NAME` / `--environment NAME` | ○ | — | リソース名に使う |
| `--rules FILE` | | `config/mysql80-to-84-parameter-rules.yml` | 変換ルール |

- **出力**: `mysql84-parameter-group.yaml`（**CloudFormation で適用する**）、`mysql80-to-mysql84-parameter-report.md`（**ゲート①のレポート**）
- **終了コード**: `0` 要レビュー・ブロックなし / `1` 残っている（解消してから適用する）
- **パラメータの扱いを変えるときはスクリプトではなくルール YAML を編集する。**
- **詳細**: [phase-1-parameter-group-cloudformation.md](../docs/phase-1-parameter-group-cloudformation.md)、サンプルは [examples/mysql84-parameter-generation/](../examples/mysql84-parameter-generation/README.md)

---

## Step 3 の前: 移行設定 YAML

3 本とも Go で、`go run ./tools/<コマンド名>` で実行する（`go.mod` はリポジトリ直下にある。引数の相対パスは実行時のカレントディレクトリ基準）。ロジックは `tools/internal/` にあり、各 `main` は CLI の配線だけを持つ。設計は [config-blue-green-generation-design.md](../docs/config-blue-green-generation-design.md)、カタログの構造は [migration-catalog-er.md](../docs/migration-catalog-er.md)。

### `collect_rds_instance_inventory`

リージョン内の RDS DB インスタンスと、そのパラメータグループの一部の値を集める。呼ぶのは `describe-db-instances` と `describe-db-parameters` だけである。

```bash
go run ./tools/collect_rds_instance_inventory \
  --region <region> --profile <profile> --output <dir>/rds-instance-inventory.json
```

| オプション | 必須 | 内容 |
|---|---|---|
| `--region REGION` | ○ | 収集対象のリージョン |
| `--output FILE` | ○ | 出力 JSON |
| `--profile PROFILE` | | AWS CLI の named profile |

- **出力**: インベントリ JSON（生成器 2 本が読む）
- **終了コード**: `0` 成功 / `1` 失敗（AWS CLI・書き込み。理由を stderr へ出す） / `2` 使い方の誤り

### `generate_blue_green_config`

移行カタログとインベントリから、パイプラインが読む設定 YAML を作る。AWS は呼ばない。

```bash
go run ./tools/generate_blue_green_config \
  --catalog config/migration-catalog.yml \
  --inventory <dir>/rds-instance-inventory.json \
  --environment staging \
  --output config/blue-green/staging.deployment.yml
```

| オプション | 必須 | 内容 |
|---|---|---|
| `--catalog FILE` | ○ | 移行カタログ（人が管理する接続定義） |
| `--inventory FILE` | ○ | `collect_rds_instance_inventory` の出力 |
| `--environment ENV` | ○ | 生成対象の環境名 |
| `--output FILE` | ○ | 生成先 YAML |

- **出力**: `config/blue-green/<environment>.deployment.yml` の形の YAML。`mysql_verification.auth_method` は `parameter_store` 固定で出る
- **終了コード**: `0` 成功 / `1` 失敗（入力の読み取り、カタログの検証・解決、書き込み。理由を stderr へ出す） / `2` 使い方の誤り

### `generate_blue_green_config_report`

上と同じ入力から、移行設定のレビュー用 Markdown を作る。**設定ファイルは書き換えない。**判定はせず、人が見る材料を並べる。

```bash
go run ./tools/generate_blue_green_config_report \
  --catalog config/migration-catalog.yml \
  --inventory <dir>/rds-instance-inventory.json \
  --environment staging \
  --output <dir>/blue-green-config-review.md
```

オプションは `generate_blue_green_config` と同じ（`--output` が Markdown になる）。

- **出力**: **ゲート②のレポート**。アプリと接続先の対応、目標インスタンスクラス、パラメータ値（Blue の実値と移行先テンプレートの宣言値の `一致` / `差異` / `比較不能`）
- **終了コード**: `0` 成功 / `1` 失敗（入力の読み取り・検証・書き込み。理由を stderr へ出す） / `2` 使い方の誤り

---

## Step 7: 後始末

### `cleanup.sh`

切替後に、Blue/Green Deployment と旧 Blue（`<source>-old1`）を削除する。**不可逆な変更操作で、パイプラインからは外してある。**

```bash
tools/cleanup.sh --config config/blue-green/staging.deployment.yml --service example-service
```

| オプション | 必須 | 既定値 | 内容 |
|---|---|---|---|
| `--config FILE` / `--service NAME` | ○ | — | 移行設定とサービス名 |
| `--mysql-user USER` | | — | 指定すると旧 Blue に接続し、逆方向レプリケーションが残っていないか確かめる |
| `--mysql-password-env NAME` | | `MYSQL_PASSWORD` | パスワードを渡す環境変数名 |
| `--ssl-ca FILE` | | — | RDS CA バンドル（VERIFY_CA で接続） |
| `--region` / `--profile` | | 設定ファイルの値 | |
| `--output-dir DIR` | | 一時ディレクトリ | 応答 JSON の保存先 |

- **前提**:
  - 設定の `actions.cleanup: approved`（無ければ何もせず `0` で終わる）
  - 切替が完了していること
  - 旧 Blue の削除保護が無効であること
- **権限**: `rds:DeleteBlueGreenDeployment` / `DeleteDBInstance` / `ModifyDBInstance` / `CreateDBSnapshot` / `AddTagsToResource` が要る。パイプラインのロールは持たないので、作業者がこの権限を持つロールを引き受ける
- **出力**: 応答 JSON。最終スナップショットは `final_snapshot_identifier`（未指定なら `<source>-final`）の固定名で作る
- **終了コード**: `0` 望ましい終了状態に到達（Deployment も旧 Blue も無い、または削除中） / `1` 到達しておらず自動では到達できない / `2` 使い方の誤り
- **詳細**: [operations-migration-run.md の B-4](../operations-migration-run.md)、[direct-blue-green-execution.md](../docs/direct-blue-green-execution.md)。冪等性の考え方は `cleanup.sh` 冒頭のコメント
