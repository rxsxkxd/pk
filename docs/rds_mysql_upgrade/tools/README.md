# tools/ — 人が手で実行するツール

`tools/` には**人が手で実行するもの**だけを置く（CI から到達するものは `scripts/`）。本書は全ツールの索引で、各ツールの用途・入出力・主なオプション・終了コードをまとめる。**背景や判定の中身は詳細ドキュメントに書き、ここからはリンクするだけにする。**

実行順に並べた手順は [operations-migration-run.md](../operations-migration-run.md) にある。本書は「このツールは何をして、何を渡して、何が返るか」を引くためのものである。

**`tools/` のツールはすべて Go である**（`go run ./tools/<名前>`）。**コマンドはすべてリポジトリのルートで実行する。**オプションの完全な一覧は各ツールの `--help` が正である。ロジックは `tools/internal/` にあり、各 `main` は CLI の配線だけを持つ。

AWS を読むツール（`collect_*` と `cleanup`）は `aws` コマンドを呼ぶ。ホストに AWS CLI があれば `go run` でよい。無ければ Linux 向けにビルドしたバイナリを compose の `awscli` コンテナで動かす（Go はコンテナに無いため）:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o .tools/collect_blue_green_prereqs ./tools/collect_blue_green_prereqs   # Apple Silicon なら arm64
docker compose --env-file .env run --rm --entrypoint .tools/collect_blue_green_prereqs awscli --db-instance-id <blue-id> --region <region>
```

## 一覧

| Step | ツール | 言語 | AWS | 用途 | ゲート |
|---|---|---|---|---|---|
| 1 | [`collect_blue_green_prereqs`](#collect_blue_green_prereqs) | Go | 読み取りのみ | Blue/Green の成立条件に要る情報を収集 | — |
| 1 | [`collect_blue_mysql_state`](#collect_blue_mysql_state) | Go（`mysql` を exec） | 呼ばない（Blue の MySQL へ接続） | AWS API では見えない項目を MySQL から収集 | — |
| 1 | [`collect_blue_upgrade_check`](#collect_blue_upgrade_check) | Go（`mysqlsh` を exec） | 呼ばない（Blue の MySQL へ接続） | MySQL Shell のアップグレードチェッカーを実行 | — |
| 1 | [`evaluate_blue_green_prereqs`](#evaluate_blue_green_prereqs) | Go | 呼ばない | 収集結果を判定し、レポートを出す | ① |
| 2 | [`collect_mysql84_parameter_inputs`](#collect_mysql84_parameter_inputs) | Go | 読み取りのみ | 8.0 パラメータグループと既定値を収集 | — |
| 2 | [`generate_mysql84_parameter_group`](#generate_mysql84_parameter_group) | Go | 呼ばない | 8.4 用 CloudFormation テンプレートとレポートを生成 | ① |
| 3 前 | [`collect_rds_instance_inventory`](#collect_rds_instance_inventory) | Go | 読み取りのみ | RDS インベントリを収集 | — |
| 3 前 | [`generate_blue_green_config`](#generate_blue_green_config) | Go | 呼ばない | 移行設定 YAML を生成 | — |
| 3 前 | [`generate_blue_green_config_report`](#generate_blue_green_config_report) | Go | 呼ばない | 移行設定のレビューレポートを生成 | ② |
| 7 | [`cleanup`](#cleanup) | Go（`mysql` を exec。任意） | **変更あり（削除）** | Blue/Green Deployment と旧 Blue の削除 | — |

どのツールも「収集」と「判定・生成」が別コマンドになっている。収集は AWS の読み取り API だけを呼んで JSON を落とし、判定・生成は AWS を呼ばずにその JSON だけを読む。**AWS を変更するのは `cleanup` だけである。**

終了コードの共通の意味:

| 終了コード | 意味 |
|---|---|
| `0` | 成功（判定系では「不適合なし」） |
| `1` | 判定系では不適合あり。収集系では AWS CLI・入力の失敗（理由を stderr へ出す） |
| `2` | 使い方の誤り（引数不足・不明な引数） |

ゲート①〜③の意味とレポートの生成元は [report-generation-flows.md](../report-generation-flows.md) にある。

---

## Step 1: 成立条件チェック

### `collect_blue_green_prereqs`

対象 Blue について、Blue/Green Deployments の成立条件に要る情報を AWS の読み取り API（`Describe*` / `Get*`）で集める。

```bash
go run ./tools/collect_blue_green_prereqs \
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

### MySQL 側の収集（2 本。結果はレポートに載る。判定には使わない）

成立条件チェックは **AWS 側（上）と MySQL 側（下の 2 本）の 2 段階**である。MySQL 側は AWS API では見えない項目を、Blue へ接続して集める。どちらも**読み取りだけ**で、判定はしない。`--output-dir` を AWS 側と同じ収集先にすると、`evaluate_blue_green_prereqs` のレポートの「MySQL 側の収集結果」に載る（無ければその節は省略と明示される）。

2 本は同じ接続規約に従う。

- **パスワードは引数に取らない。**`--password-env` が指す環境変数（既定 `MYSQL_PASSWORD`）で渡す。`mysql` へは `MYSQL_PWD`、`mysqlsh` へは標準入力で渡る
- TLS は **`--ssl-mode`** で選ぶ（下の「MySQL の TLS」）。**既定は VERIFY_CA で、`--ssl-ca` が必須**
- `--output-dir` に `collect_blue_green_prereqs` の収集先を指定すると、AWS 側の結果と同じディレクトリに並ぶ

`mysql` / `mysqlsh` の両方が入っている compose の `mysql` コンテナ（`mysql:8.4.11`。RDS の CA は `/certs/rds/global-bundle.pem`）で動かす想定である。Go はコンテナに無いので、Linux 向けにビルドしたバイナリを渡す。

```bash
# ホストでビルド（コンテナのアーキテクチャに合わせる。Apple Silicon なら arm64）
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o .tools/collect_blue_mysql_state ./tools/collect_blue_mysql_state
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o .tools/collect_blue_upgrade_check ./tools/collect_blue_upgrade_check

# パスワードは対話入力で環境変数へ置く（エコーしない）
read -rs MYSQL_PASSWORD && export MYSQL_PASSWORD
docker compose --env-file .env run --rm -e MYSQL_PASSWORD mysql \
  .tools/collect_blue_mysql_state \
  --host <blue-endpoint> --user <user> --ssl-ca /certs/rds/global-bundle.pem --output-dir <収集先>
```

接続ユーザーには `SELECT`・`PROCESS`・`REPLICATION CLIENT`・`SHOW VIEW`・`EVENT`・`TRIGGER` などの読み取り権限が要る（アップグレードチェッカーの検査項目による）。

#### MySQL の TLS（`--ssl-mode` / `--ssl-ca`）

MySQL へ接続する 3 本（`collect_blue_mysql_state`・`collect_blue_upgrade_check`・`cleanup` の逆方向レプリケーション確認）は同じ規則に従う（実装は `tools/internal/mysqlcli`）。

| `--ssl-mode` | TLS | サーバー証明書 | `--ssl-ca` | 用途 |
|---|---|---|---|---|
| `VERIFY_CA`（**既定**） | 必須 | チェーンを検証（ホスト名は見ない） | **必須** | 通常はこれ。RDS の CA バンドルを渡す |
| `VERIFY_IDENTITY` | 必須 | チェーンとホスト名を検証 | **必須** | 最も厳しい。RDS のエンドポイント名で接続するとき |
| `REQUIRED` | 必須 | 検証しない | 渡せない | 暗号化だけ必要で CA を用意できないとき |
| `PREFERRED` | 任意（使えれば使う） | 検証しない | 渡せない | TLS の有無を問わず接続したいとき（平文へ黙って落ちうる） |
| `DISABLED` | 使わない（強制的に平文） | — | 渡せない | TLS を無効にしたサーバーや検証用。パスワードも平文で流れる |

- 検証しない 3 つ（`REQUIRED` / `PREFERRED` / `DISABLED`）は、指定すると **stderr に警告**を出す。明示しない限り使われない
- 検証する 2 つで `--ssl-ca` が無い、または検証しない 3 つで `--ssl-ca` を渡した場合は、接続する前に使い方の誤りとして止める（指定の意図と挙動を食い違わせないため）
- `DISABLED` / `PREFERRED` では `--get-server-public-key` を付ける。MySQL 8 の既定の認証方式（`caching_sha2_password`）が TLS なしでパスワードを送るのに必要なためである
- 5 つのモードとも、実際の MySQL 8.0 に対して動作を確かめてある（`VERIFY_IDENTITY` はホスト名が証明書と一致しなければ拒否される）

#### `collect_blue_mysql_state`

`mysql` コマンドで次を取り、`blue-mysql-state.json` に書く。

| 取るもの | 対応するチェック |
|---|---|
| `version`・`binlog_format` の実効値 | 0-1-02（パラメータグループの値と食い違うことがある） |
| `SHOW REPLICA STATUS` | 0-1-06 外部 binlog レプリカ（**AWS API では確認できない**。要 `REPLICATION CLIENT`） |
| ユーザースキーマの InnoDB 以外のテーブル | 移行ガイドの 0-2（MyISAM の棚卸し） |

| オプション | 必須 | 既定値 | 内容 |
|---|---|---|---|
| `--host` / `--user` / `--ssl-ca` | ○ | — | 接続先 Blue、ユーザー、RDS の CA バンドル |
| `--output-dir DIR` | ○ | — | 出力先 |
| `--port` | | `3306` | |
| `--password-env NAME` | | `MYSQL_PASSWORD` | パスワードを載せた環境変数の名前 |
| `--mysql PATH` | | `mysql` | `mysql` コマンドのパス |
| `--timeout` | | `2m` | 全体のタイムアウト |

- **終了コード**: `0` 収集完了 / `1` 接続・権限・クエリの失敗（どれか 1 つでも失敗すれば何も書かない） / `2` 使い方の誤り

#### `collect_blue_upgrade_check`

`mysqlsh -- util check-for-server-upgrade --output-format=JSON`（移行ガイドの 0-3）を実行し、`blue-upgrade-check.json` に書く。チェッカーの JSON はそのまま `report` に入れ、件数（`error_count` / `warning_count` / `notice_count`）と `mysqlsh` の終了コードを取り出して並べる。

オプションは上と同じで、`--mysql` の代わりに `--mysqlsh PATH`。加えて `--target-version`（既定 `8.4.9`。**`mysqlsh` 自身より新しい版は指定できない**）があり、`--timeout` の既定は `10m` である。

- **終了コード**: `0` 収集完了（**チェッカーが問題を見つけても `0`**。件数は JSON に残る） / `1` JSON を取れなかった（接続・権限の失敗など） / `2` 使い方の誤り

### `evaluate_blue_green_prereqs`

上の収集結果を判定し、`OK` / `REVIEW` / `STOP` を出す。AWS は呼ばない。

```bash
go run ./tools/evaluate_blue_green_prereqs \
  --input-dir <収集先> --output <収集先>/prereqs-evaluation-report.md
```

| オプション | 必須 | 内容 |
|---|---|---|
| `--input-dir DIR` | ○ | `collect_blue_green_prereqs` の出力先 |
| `--output FILE` | | Markdown レポートの出力先（省略時は標準出力の一覧だけ） |

- **出力**: 標準出力に判定一覧と、MySQL 側のファイルの有無（`あり` / `省略`）。`--output` を付けると**ゲート①のレポート**（判定に加えて観測値と取得元）
- **MySQL 側の収集結果**: 入力ディレクトリに `blue-mysql-state.json`（`collect_blue_mysql_state`）や `blue-upgrade-check.json`（`collect_blue_upgrade_check`）があれば、レポートの「MySQL 側の収集結果」に載せる——binlog_format の実効値、`SHOW REPLICA STATUS`、InnoDB 以外のテーブル、アップグレードチェッカーの件数・検査項目・検出された問題（Error を先に）。**ファイルが無い節は「省略した」と、どのコマンドで取れるかを明示する。**判定と終了コードには使わない
- **終了コード**: `0` `STOP` なし / `1` `STOP` が 1 件以上。`REVIEW` は終了コードに影響しない（人が確認する）
- **詳細**: [report-generation-flows.md](../report-generation-flows.md)、サンプルは [examples/blue-green-prereqs/](../examples/blue-green-prereqs/README.md)

---

## Step 2: パラメータグループ

### `collect_mysql84_parameter_inputs`

移行元の 8.0 カスタムパラメータグループと、8.0 / 8.4 の既定値を集める。

```bash
go run ./tools/collect_mysql84_parameter_inputs \
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

### `generate_mysql84_parameter_group`

収集結果と変換ルールから、8.4 用パラメータグループの CloudFormation テンプレートとレポートを作る。AWS は呼ばない。

```bash
go run ./tools/generate_mysql84_parameter_group \
  --input-dir <収集先> --output-dir <生成先> --system <name> --environment <env>
```

| オプション | 必須 | 既定値 | 内容 |
|---|---|---|---|
| `--input-dir DIR` | ○ | — | `collect_mysql84_parameter_inputs` の出力先 |
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

### `cleanup`

切替後に、Blue/Green Deployment と旧 Blue（`<source>-old1`）を削除する。**不可逆な変更操作で、パイプラインからは外してある。**

```bash
go run ./tools/cleanup --config config/blue-green/staging.deployment.yml --service example-service
```

| オプション | 必須 | 既定値 | 内容 |
|---|---|---|---|
| `--config FILE` / `--service NAME` | ○ | — | 移行設定とサービス名 |
| `--mysql-user USER` | | — | 指定すると旧 Blue に接続し、逆方向レプリケーションが残っていないか確かめる |
| `--mysql-password-env NAME` | | `MYSQL_PASSWORD` | パスワードを渡す環境変数名。空なら端末から対話入力する（エコーしない。端末が無ければ止める） |
| `--ssl-mode MODE` | | `VERIFY_CA` | 旧 Blue への接続の TLS（上の「MySQL の TLS」） |
| `--ssl-ca FILE` | | — | RDS CA バンドル（`VERIFY_CA` / `VERIFY_IDENTITY` では必須） |
| `--mysql-port` / `--mysql` | | `3306` / `mysql` | 旧 Blue のポートと mysql コマンドのパス |
| `--region` / `--profile` | | 設定ファイルの値 | |
| `--output-dir DIR` | | 一時ディレクトリ | 応答 JSON の保存先 |

- **前提**:
  - 設定の `actions.cleanup: approved`（無ければ何もせず `0` で終わる）
  - 切替が完了していること
  - 旧 Blue の削除保護が無効であること
- **権限**: `rds:DeleteBlueGreenDeployment` / `DeleteDBInstance` / `ModifyDBInstance` / `CreateDBSnapshot` / `AddTagsToResource` が要る。パイプラインのロールは持たないので、作業者がこの権限を持つロールを引き受ける
- **出力**: 応答 JSON。最終スナップショットは `final_snapshot_identifier`（未指定なら `<source>-final`）の固定名で作る
- **終了コード**: `0` 望ましい終了状態に到達（Deployment も旧 Blue も無い、または削除中） / `1` 到達しておらず自動では到達できない / `2` 使い方の誤り
- **詳細**: [operations-migration-run.md の B-4](../operations-migration-run.md)、[direct-blue-green-execution.md](../docs/direct-blue-green-execution.md)。冪等性の考え方は `tools/internal/cleanup` 冒頭のコメント
