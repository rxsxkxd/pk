# Blue/Green 設定 YAML 生成支援ツール（最小設計）

## 1. 目的

既存の `config/blue-green/{staging,production}.yml` を、RDS の実情報と人が管理する対応表から生成する。設定ファイルへの手入力を減らしつつ、移行の最終確認と承認は人が行う。

このツールは設定を**生成するだけ**であり、RDS、CloudFormation、Blue/Green deployment を変更しない。

## 2. 前提と範囲

- Blue/Green の操作単位は RDS DB インスタンスである。
- 同じ RDS インスタンスを複数アプリケーションが共有している場合も、移行定義は一つだけ生成する。
- RDS のエンジンバージョンと移行元パラメータグループは AWS CLI の読み取り結果を使う。
- MySQL 内の論理 DB（schema）と、それを利用するアプリケーションの対応は AWS RDS API からは得られない。そのため、自前 YAML で管理する。
- 論理 DB の存在、アプリケーション接続、パラメータグループの中身、移行可否はこのツールでは検証しない。生成結果のレビューと最終確認は人が行う。

## 3. 構成

構成は、入力 YAML 一つ、AWS CLI 収集スクリプト一つ、生成スクリプト一つだけとする。

```text
config/migration-catalog.yml                 # 人が管理する対応表・移行方針
scripts/collect_rds_instance_inventory.sh    # AWS CLI の read-only 収集
scripts/generate_blue_green_config.py        # YAML 生成
artifacts/rds-instance-inventory.json        # 収集結果（一時・レビュー用）
config/blue-green/<environment>.yml          # 生成結果
```

## 4. 入力

### 4-1. RDS インベントリ

`collect_rds_instance_inventory.sh` が、対象リージョンに対して次だけを実行する。

```bash
aws rds describe-db-instances --region <region> --output json
```

結果は `artifacts/rds-instance-inventory.json` に保存する。収集スクリプトは `describe-db-instances` の応答をそのまま `DBInstances` に保持し、実行時に指定した `--region` を最上位の `aws_region` として付与する。`aws_region` はカタログに個別記載しない。生成時に利用するのは、各 DB インスタンスの次の値である。

- `DBInstanceIdentifier`
- `Engine`
- `EngineVersion`
- `DBParameterGroups[].DBParameterGroupName`

AWS CLI の認証は利用者または実行基盤が提供する通常の AWS 認証情報を使う。スクリプトは `--profile` と `--region` を受け取れるようにするが、認証情報をファイルへ出力しない。

### 4-2. 移行カタログ

`config/migration-catalog.yml` は人が管理する正本である。RDS API では得られない対応関係と、8.4 側で人が決める値だけを記載する。

```yaml
databases:
  # ルートキー自体が MySQL schema 名。1 schema を 1 定義として管理する。
  order:
    # schema を利用するアプリケーション（レビュー用メタデータ）。
    services: [order-api, order-batch]
    environments:
      development:
        # AWS profile とリージョンは収集・実行コマンドで指定する。
        # primary は一つの RDS ホストと、このルートの一つの schema の組み合わせ。
        primary:
          output_service_name: order-primary
          host:
            rds_instance_identifier: shared-order-development-mysql80
          target:
            engine_version: "8.4.10"
            db_instance_class: db.t4g.small
            db_parameter_group_name: shared-order-development-mysql84-v1
            parameter_group_template_path: generated/parameter-groups/shared-order-development-mysql84.yaml
      staging:
        primary:
          output_service_name: order-primary
          host:
            rds_instance_identifier: shared-order-staging-mysql80
          target:
            engine_version: "8.4.10"
            db_instance_class: db.t4g.medium
            db_parameter_group_name: shared-order-staging-mysql84-v1
            parameter_group_template_path: generated/parameter-groups/shared-order-staging-mysql84.yaml
      production:
        primary:
          output_service_name: order-primary
          host:
            # RDS の DBInstanceIdentifier。インベントリと照合して情報を補完するキー。
            rds_instance_identifier: shared-order-production-mysql80
          # 8.4 側の移行判断。パラメータグループは Phase 1 で別途作成済みであること。
          target:
            engine_version: "8.4.10"
            db_instance_class: db.r6g.large
            db_parameter_group_name: shared-order-production-mysql84-v1
            parameter_group_template_path: generated/parameter-groups/shared-order-production-mysql84.yaml

  # 別ホストにある schema は、独立した databases 要素として定義する。
  payment:
    services: [payment-api]
    environments:
      development:
        primary:
          output_service_name: payment-primary
          host:
            rds_instance_identifier: shared-payment-development-mysql80
          target:
            engine_version: "8.4.10"
            db_instance_class: db.t4g.small
            db_parameter_group_name: shared-payment-development-mysql84-v1
            parameter_group_template_path: generated/parameter-groups/shared-payment-development-mysql84.yaml
      staging:
        primary:
          output_service_name: payment-primary
          host:
            rds_instance_identifier: shared-payment-staging-mysql80
          target:
            engine_version: "8.4.10"
            db_instance_class: db.t4g.medium
            db_parameter_group_name: shared-payment-staging-mysql84-v1
            parameter_group_template_path: generated/parameter-groups/shared-payment-staging-mysql84.yaml
      production:
        primary:
          output_service_name: payment-primary
          host:
            rds_instance_identifier: shared-payment-production-mysql80
          target:
            engine_version: "8.4.10"
            db_instance_class: db.r6g.large
            db_parameter_group_name: shared-payment-production-mysql84-v1
            parameter_group_template_path: generated/parameter-groups/shared-payment-production-mysql84.yaml
```

`databases.<schema>` は一つの MySQL schema を表す。各環境の `primary` は一つの `host` とその schema の組み合わせだけを表し、複数 host や複数 schema は入れない。schema が別の RDS ホストにある場合は、その schema 用の `databases.<schema>` を追加する。`output_service_name` が、生成先 `config/blue-green/<environment>.yml` の `services` キーになる。`--environment development`、`staging`、`production` の指定時は、各 schema 定義配下の同名環境を取り出して生成する。したがって、同じ環境で同一 RDS インスタンスまたは同じ `output_service_name` を複数の schema 定義に重複して書かない。

## 5. 生成処理

`generate_blue_green_config.py` は、移行カタログと RDS インベントリ JSON を読み込み、指定環境の `config/blue-green/<environment>.yml` を生成する。

生成する値は次のとおりである。

| 出力項目 | 取得元 |
|---|---|
| `environment` | 生成時の `--environment` 引数 |
| `aws_region` | RDS インベントリ収集時の `--region`（インベントリ最上位の `aws_region`） |
| `source_db_instance_identifier` | 移行カタログの `databases.<schema>.environments.<environment>.primary.host.rds_instance_identifier` |
| `source_engine_version` | RDS インベントリの `EngineVersion` を `8.0` のような major.minor へ正規化 |
| `source_db_parameter_group_name` | RDS インベントリ |
| `target_engine_version`、`target_db_instance_class`、`target_db_parameter_group_name`、`target_parameter_group_template_path` | 移行カタログ |
| `protection_snapshot_identifier` | `<source_db_instance_identifier>-pre-bg` を生成 |
| `final_snapshot_identifier` | `<source_db_instance_identifier>-final` を生成 |
| `actions` | 常に `build`、`switchover`、`cleanup` を `pending` で生成 |

生成時に行う機械的な停止条件は最小限にする。

- カタログで指定した DB インスタンス ID がインベントリにない
- インベントリに `aws_region` がなく、生成先設定の実行リージョンを決定できない
- 対象インスタンスの `Engine` が `mysql` ではない
- 同じ環境内で一つの DB インスタンス ID または `output_service_name` が複数の schema 定義に重複する
- 生成に必要な `target` の値が欠けている

これ以外の妥当性は自動判定しない。特に、アプリケーションと論理 DB の対応、目標インスタンスクラス、パラメータグループ内容はレビュー対象とする。

## 6. 操作イメージ

```bash
# 1. AWS から現状の RDS インスタンス情報を読み取り保存する。
scripts/collect_rds_instance_inventory.sh \
  --region ap-northeast-1 \
  --profile readonly \
  --output artifacts/rds-instance-inventory.json

# 2. 人が config/migration-catalog.yml をレビュー・更新する。
#    カタログにはリージョンを書かず、RDS インスタンス ID と移行設定だけを管理する。

# 3. 指定環境の Blue/Green 設定を生成する。
python3 scripts/generate_blue_green_config.py \
  --catalog config/migration-catalog.yml \
  --inventory artifacts/rds-instance-inventory.json \
  --environment production \
  --output config/blue-green/production.yml

# 4. 生成結果を人がレビューし、必要な移行承認時だけ actions を pending から変更する。
git diff -- config/blue-green/production.yml
```

## 7. コーディング中のテスト

実装・変更時は、実環境のカタログ、AWS、既存の `config/blue-green/*.yml` をテスト対象にしない。

- テスト fixture は `development`、`staging`、`production` の三環境を含むが、RDS インスタンス ID はすべて `example-service-test-*` のダミー値である。
- テスト fixture は二つの `databases.<schema>` を定義し、各環境でそれぞれ異なる RDS ホストを参照する。
- [migration-catalog.test.yml](examples/config-blue-green-generation/migration-catalog.test.yml) と [rds-instance-inventory.test.json](examples/config-blue-green-generation/rds-instance-inventory.test.json) をダミー入力として使う。
- `blue-green.<environment>.expected.yml` を生成結果の期待値とし、生成 YAML を構文ではなくデータ構造として比較する。
- 実行済みの結果は [test-result.md](examples/config-blue-green-generation/test-result.md) に残す。
- `tests/test_generate_blue_green_config.sh` は AWS CLI をダミーコマンドに差し替える。実 AWS API は呼び出さない。
- 収集 JSON と生成先 YAML はすべて `mktemp` で作成する一時ディレクトリに出力し、テスト終了時に削除する。

```bash
tests/test_generate_blue_green_config.sh
```

テストにも PyYAML が必要である。未導入の場合は次を一度だけ実行する。

```bash
python3 -m pip install 'PyYAML==6.0.2'
```

## 8. 実装しないこと

- MySQL クライアントによる schema 一覧・実効値・接続可否の収集
- アプリケーション設定や Secret の探索
- RDS パラメータグループ、CloudFormation、Blue/Green deployment の作成・変更
- 自動承認、`actions.*` の `approved` 生成
- 環境ごとの生成済みファイルを自動で本番へ反映する処理

これらは誤判定や意図しない変更の影響が大きいため、最小構成では対象外とする。
