# Blue/Green 設定 YAML 生成支援ツール（最小設計）

## 1. 目的

既存の `config/blue-green/{staging,production}.deployment.yml` を、RDS の実情報と人が管理する対応表から生成する。設定ファイルへの手入力を減らしつつ、移行の最終確認と承認は人が行う。

このツールは設定を**生成するだけ**であり、RDS、CloudFormation、Blue/Green deployment を変更しない。

## 2. 前提と範囲

- Blue/Green の操作単位は RDS DB インスタンスである。
- 同じ RDS インスタンスを複数アプリケーションが共有している場合も、移行定義は一つだけ生成する。
- RDS のエンジンバージョンと移行元パラメータグループは AWS CLI の読み取り結果を使う。
- MySQL 内の論理 DB（schema）と、それを利用するアプリケーションの対応は AWS RDS API からは得られない。そのため、自前 YAML で管理する。
- 論理 DB の存在、アプリケーション接続、パラメータグループの中身、移行可否はこのツールでは検証しない。生成結果のレビューと最終確認は人が行う。

## 3. 構成

構成は、入力 YAML 一つ、収集コマンド一つ、生成コマンド一つだけとする。収集と生成はどちらも Go で、**別コマンドとして分ける**（収集は AWS を呼び、生成は呼ばない）。

```text
config/migration-catalog.yml                     # 人が管理する対応表・移行方針
scripts/collect_rds_instance_inventory/          # 収集コマンド（CLI の配線だけ）
scripts/generate_blue_green_config/              # YAML 生成コマンド（CLI の配線だけ）
scripts/generate_blue_green_config_report/       # レポート生成コマンド（CLI の配線だけ）
scripts/internal/common/                         # インベントリ JSON の型（契約）、原子的書き込み
scripts/internal/collect/                        # AWS CLI の read-only 収集
scripts/internal/generate/                       # カタログの検証・解決と YAML 組み立て
scripts/internal/cfn/                            # CloudFormation テンプレートの読み取り（短縮記法対応）
scripts/internal/report/                         # 切替前レビュー用 Markdown の組み立て
artifacts/rds-instance-inventory.json            # 収集結果（一時・レビュー用）
config/blue-green/<environment>.deployment.yml   # 生成結果（CI が読む正のデータ）
artifacts/blue-green-<environment>-review.md     # 生成結果（人が読むレビュー資料）
```

処理単位でライブラリを分けている。**インベントリ JSON の型は収集器が書き生成器が読む「契約」なので `internal/common` に一本化し、片側だけ変えて黙って壊れないようにする。**コマンド側は引数の受け取りと呼び出しだけで、判定ロジックを持たない。

## 4. 入力

### 4-1. RDS インベントリ

`collect_rds_instance_inventory`（Go）が、対象リージョンに対して次の読み取り API だけを実行する。

```bash
aws rds describe-db-instances --region <region> --output json
# 上で見つかったパラメータグループごとに 1 回
aws rds describe-db-parameters --db-parameter-group-name <name> --region <region> --output json
```

結果は `artifacts/rds-instance-inventory.json` に保存する。収集器は `describe-db-instances` の応答をそのまま `DBInstances` に保持し、実行時に指定した `--region` を最上位の `aws_region` として付与する。`aws_region` はカタログに個別記載しない。生成時に利用するのは、各 DB インスタンスの次の値である。

- `DBInstanceIdentifier`
- `Engine`
- `EngineVersion`
- `DBInstanceClass`
- `DBParameterGroups[].DBParameterGroupName`

さらに、確認用として各パラメータグループのパラメータ実値を `ParameterGroups.<グループ名>.Parameters` に採取する。**収集器は判定を行わない。**同じパラメータグループを複数インスタンスが共有していても API 呼び出しは 1 回である。

採取対象は収集器の `CollectedParameters` で決める。**現在は `time_zone` だけ**である（8.0 → 8.4 の論点であるため）。対象を増やすときはここへパラメータ名を足す。パラメータ名をキーにしてあるので、**インベントリと生成結果の構造は変わらない。**

```json
{
  "aws_region": "ap-northeast-1",
  "DBInstances": [ ... ],
  "ParameterGroups": {
    "order-production-mysql80-v1": {
      "Parameters": { "time_zone": { "Value": "Asia/Tokyo", "Source": "user" } }
    },
    "shared-development-mysql80-v1": {
      "Parameters": { "time_zone": { "Value": "UTC", "Source": "engine-default" } }
    }
  }
}
```

`Source` が `engine-default` なら、パラメータグループでは設定しておらずエンジン既定値である。応答に現れないパラメータは採取しない（存在しないことを収集器が判定しない）。

AWS CLI の認証は利用者または実行基盤が提供する通常の AWS 認証情報を使う。収集器は `--profile` と `--region` を受け取れるようにするが、認証情報をファイルへ出力しない。**AWS SDK ではなく AWS CLI を exec する**——認証経路をリポジトリ全体で 1 本に保ち、`go.mod` へ依存を追加せず、PATH 上の `aws` を差し替えるだけでテストからモックできるようにするためである。

### 4-2. 移行カタログ

`config/migration-catalog.yml` は人が管理する正本である。RDS API では得られない接続定義と、8.4 側で人が決める値だけを記載する。**構造は [migration-catalog-er.md](migration-catalog-er.md) を正とする。**

```yaml
applications:
  # database.yml を共有するコードベース単位。デプロイ単位ではない。
  order:
    connections:
      # 接続名は全環境で共通。コードの connects_to が参照する。
      primary:
        environments:
          production:
            # 実定義: 環境変数 ORDER_DB_HOST / ORDER_DB_NAME
            rds_instance: order-production-mysql80
            schema_name: order_production
            target:
              # db_parameter_group_name だけが必須。
              db_parameter_group_name: production-mysql84-v1
              # 任意。engine_version を省略すると共通ターゲットへ上げる。
              # db_instance_class を省略すると Blue の実値を踏襲する。
              # engine_version: "8.4.11"
              # db_instance_class: db.r6g.large
            # この DB だけ別のパラメータを使う場合に書く（キー単位で上書き）。
            # 省略するとルートの mysql_verification を参照する。
            # mysql_verification:
            #   parameter_name: /rds-bg/order/mysql-password
            #   user_parameter_name: /rds-bg/order/mysql-user

# DB を配置している環境の一覧。実体は AWS アカウント（AWS CLI のプロファイルに相当）。
database_environments:
  - development
  - staging
  - production

parameter_groups:
  production-mysql84-v1:
    template_path: generated/parameter-groups/production.yaml

# Step 4 の MySQL 接続設定の、全 DB 共通の既定値。
# ユーザー名とパスワードは SSM Parameter Store の SecureString に置き、
# ここにはパラメータ名だけを書く。
mysql_verification:
  enabled: false
  parameter_name: /rds-bg/mysql-password
  user_parameter_name: /rds-bg/mysql-user
  port: 3306
```

**生成単位は RDS DB インスタンスである。** 同じ `rds_instance` を指す接続は 1 つの Blue/Green deployment にまとめられ、生成先 `config/blue-green/<environment>.deployment.yml` の `services` キーには **RDS インスタンス識別子**が入る。

`--environment development` / `staging` / `production` の指定時は、各接続配下の同名環境を取り出して生成する。環境名は `database_environments` に列挙したものだけを受け付ける。

そのインスタンスに載るスキーマは、切替の影響範囲を辿るために持つ。実行スクリプトは参照しないが、生成結果の `schemas` に反映される。

**`source_db_parameters` は切替前の確認専用である。** 8.0 → 8.4 では `time_zone` の扱いが論点になる（`DEFAULT CURRENT_TIMESTAMP` の `datetime` 列への影響。詳細は [reference/mysql-timezone-problem-summary.md](reference/mysql-timezone-problem-summary.md)）。Blue のパラメータグループの実値を生成結果へ載せておき、Step 2 で作る 8.4 パラメータグループが同じ値になっているかを人がレビューする。実行スクリプトはこの項目を読まず、判定にも使わない。

```yaml
    source_db_parameters:
      time_zone:
        value: Asia/Tokyo
        source: user
```

**MySQL 接続設定はルートの `mysql_verification` を既定値とし、接続配下の指定でキー単位に上書きする。** 環境ごとに AWS アカウントが分かれるため、同じ SSM パラメータ名を全環境で共通に使える。DB ごとに分ける必要があるときだけ、その接続の `environments.<環境>` 配下へ書く。ユーザー名とパスワードそのものはカタログへ書けない（`user` / `password` を書くと生成時に失敗する）。

## 5. 生成処理

`generate_blue_green_config`（Go）は、移行カタログと RDS インベントリ JSON を読み込み、指定環境の `config/blue-green/<environment>.deployment.yml` を生成する。**AWS を一切呼ばない。**

カタログの未知キーは黙って無視せず、誤字として落とす（`yaml:",inline"` で拾って報告する）。

生成する値は次のとおりである。

| 出力項目 | 取得元 |
|---|---|
| `environment` | 生成時の `--environment` 引数 |
| `aws_region` | RDS インベントリ収集時の `--region`（インベントリ最上位の `aws_region`） |
| `services` のキー | 接続の `rds_instance`（RDS インスタンス識別子） |
| `source_db_instance_identifier` | 同上 |
| `source_engine_version` | RDS インベントリの `EngineVersion` を `8.0` のような major.minor へ正規化 |
| `source_db_parameter_group_name` | RDS インベントリ |
| `target_db_parameter_group_name` | 移行カタログの `target.db_parameter_group_name`（**必須**） |
| `target_engine_version` | 移行カタログの `target.engine_version`。**省略時は共通ターゲット（生成器の `DEFAULT_TARGET_ENGINE_VERSION`）** |
| `target_db_instance_class` | 移行カタログの `target.db_instance_class`。**省略時は RDS インベントリの `DBInstanceClass` を踏襲** |
| `target_parameter_group_template_path` | 移行カタログの `parameter_groups.<name>.template_path` |
| `schemas` | そのインスタンスを指す接続の `schema_name` を集約（影響範囲のレビュー用） |
| `source_db_parameters` | RDS インベントリの `ParameterGroups.<Blue のグループ名>.Parameters` を、パラメータ名をキーに `value` / `source` で載せる。**確認用**で実行スクリプトは参照しない |
| `mysql_verification` | ルートの `mysql_verification` を既定値とし、接続配下の指定でキー単位に上書き（どちらも無ければ `enabled: false`）。`auth_method` は `parameter_store` 固定で出力する。`enabled: true` なら `parameter_name` と `user_parameter_name` の両方が必須で、`user` と `password` はカタログへ書けない |
| `protection_snapshot_identifier` | `<source_db_instance_identifier>-pre-bg` を生成 |
| `final_snapshot_identifier` | `<source_db_instance_identifier>-final` を生成 |
| `actions` | 常に `build`、`switchover`、`cleanup` を `pending` で生成 |

生成時に行う機械的な停止条件は最小限にする。

- カタログで指定した DB インスタンス ID がインベントリにない
- インベントリに `aws_region` がなく、生成先設定の実行リージョンを決定できない
- 対象インスタンスの `Engine` が `mysql` ではない
- `target.db_parameter_group_name` が指定されていない
- `target.db_parameter_group_name` が `parameter_groups` に定義されていない
- 接続の環境が `database_environments` に列挙されていない
- 同じ `rds_instance` を指す接続のあいだで `target` または `mysql_verification` が食い違う

これ以外の妥当性は自動判定しない。特に、アプリケーションと接続先の対応、目標インスタンスクラス、パラメータグループ内容はレビュー対象とする。

### 5-1. レビュー用レポート

`generate_blue_green_config_report`（Go）は、**YAML 生成とは別コマンド**として同じ入力から Markdown を組み立てる。設定ファイルには一切触らず、`.md` を 1 本出すだけである。判定の重複を避けるため、deployment の組み立ては `internal/generate` を再利用する。

**このレポートも可否を判定しない。** 上で「自動判定しない」と決めた事項を、人がレビューしやすい形に並べるためのものである。

| 節 | 内容 |
|---|---|
| 概要 | 環境、リージョン、実行単位数、接続定義数、アプリ数 |
| 移行元と移行先 | インスタンスごとのバージョン・パラメータグループ・インスタンスクラスと、移行先パラメータグループの元テンプレート |
| 影響範囲 | インスタンスごとのスキーマと**接続元（アプリ.接続名）**。生成結果にはアプリ名が残らないため、ここで補う |
| パラメータの現状と適用予定値 | **Blue のパラメータグループの実値と、移行先テンプレートが宣言している値を直接突き合わせる。**判定は `一致` / `差異` / `比較不能`（組み込み関数）/ `テンプレート未宣言` / `テンプレート未確認` |
| Step 4 の MySQL 接続検証 | 有効・無効と SSM パラメータ名、ポート、TLS。**認証情報そのものは出さない** |
| 要確認事項 | チェックボックス形式。同居インスタンス、**パラメータの差異・比較不能・未宣言**、共有された移行先パラメータグループ、無効な接続検証、`actions` の承認状態 |

適用予定値は、カタログの `parameter_groups.<name>.template_path` が指す CloudFormation テンプレートから読む。**短縮記法（`!Ref` / `!Sub`）を長形式へ正規化して読み、値が組み込み関数の項目は「比較不能」として比較対象から外す**（`internal/cfn`）。テンプレートは Step 2 の成果物なので、**まだ無い段階でもレポートは失敗させず**「テンプレート未確認」として出し、要確認事項に理由を載せる。`template_path` は実行時のカレントディレクトリ基準で解決する。

出力先は Git 管理しない `artifacts/` を想定する（`.gitignore` 済み）。生成結果の YAML と違い、レポートは CI の入力ではない。

## 6. 操作イメージ

```bash
# 1. AWS から現状の RDS インスタンス情報を読み取り保存する。
go run ./scripts/collect_rds_instance_inventory \
  --region ap-northeast-1 \
  --profile readonly \
  --output "$PWD/artifacts/rds-instance-inventory.json"

# 2. 人が config/migration-catalog.yml をレビュー・更新する。
#    カタログにはリージョンを書かず、接続定義と移行設定だけを管理する。

# 3. 指定環境の Blue/Green 設定を生成する。
go run ./scripts/generate_blue_green_config \
  --catalog "$PWD/config/migration-catalog.yml" \
  --inventory "$PWD/artifacts/rds-instance-inventory.json" \
  --environment production \
  --output "$PWD/config/blue-green/production.deployment.yml"

# 4. レビュー用の Markdown を出す（設定ファイルは書き換えない）。
go run ./scripts/generate_blue_green_config_report \
  --catalog "$PWD/config/migration-catalog.yml" \
  --inventory "$PWD/artifacts/rds-instance-inventory.json" \
  --environment production \
  --output "$PWD/artifacts/blue-green-production-review.md"

# 5. 生成結果とレポートを人がレビューし、必要な移行承認時だけ actions を pending から変更する。
git diff -- config/blue-green/production.deployment.yml
```

## 7. コーディング中のテスト

実装・変更時は、実環境のカタログ、AWS、既存の `config/blue-green/*.yml` をテスト対象にしない。

- テスト fixture は `development`、`staging`、`production` の三環境を含むが、RDS インスタンス ID はすべて `example-service-test-*` のダミー値である。
- テスト fixture は二つの `applications` を定義し、次を意図的に含めて生成器の分岐を通す。
  - 1 アプリに複数接続（マルチ DB）
  - development で 2 接続が 1 インスタンスを共有し、1 deployment へまとめられること
  - production で 2 アプリが 1 インスタンスを共有すること
  - `target` の省略（`engine_version` は共通ターゲットへ、`db_instance_class` は Blue を踏襲）
- [migration-catalog.test.yml](examples/config-blue-green-generation/migration-catalog.test.yml) と [rds-instance-inventory.test.json](examples/config-blue-green-generation/rds-instance-inventory.test.json) をダミー入力として使う。
- `blue-green.<environment>.expected.yml` を生成結果の期待値とし、生成 YAML を構文ではなくデータ構造として比較する。
- 実行済みの結果は [test-result.md](examples/config-blue-green-generation/test-result.md) に残す。
- ロジックの単体テストは `scripts/internal/*/[a-z]*_test.go` にある。リポジトリ直下で `go test ./...` を実行し、AWS へは接続しない（`internal/collect` は PATH 上の `aws` をダミーへ差し替えて引数の組み立てを検証する）。
- `tests/test_generate_blue_green_config.sh` はコマンドを通した E2E である。AWS CLI をダミーコマンドに差し替え、実 AWS API は呼び出さない。ダミーは `describe-db-instances` と `describe-db-parameters` を fixture から返し分け、それ以外を呼んだら失敗する。
- **`go.mod` はリポジトリ直下にある。**`go run ./scripts/<コマンド名>` の形で呼べば go コマンドが作業ディレクトリを変えないため、`--output` などの相対パスは実行時のカレントディレクトリ基準で解決される。
- 収集 JSON と生成先 YAML はすべて `mktemp` で作成する一時ディレクトリに出力し、テスト終了時に削除する。

```bash
tests/test_generate_blue_green_config.sh
```

アサーションは Ruby（`ruby -ryaml -rjson`）で書いてある。**YAML / JSON はどちらも標準ライブラリなので、追加導入は要らない。**

## 8. 実装しないこと

- MySQL クライアントによる schema 一覧・実効値・接続可否の収集
- アプリケーション設定や Secret の探索
- RDS パラメータグループ、CloudFormation、Blue/Green deployment の作成・変更
- 自動承認、`actions.*` の `approved` 生成
- 環境ごとの生成済みファイルを自動で本番へ反映する処理

これらは誤判定や意図しない変更の影響が大きいため、最小構成では対象外とする。
