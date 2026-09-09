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

結果は `artifacts/rds-instance-inventory.json` に保存する。生成時に利用するのは、各 DB インスタンスの次の値である。

- `DBInstanceIdentifier`
- `Engine`
- `EngineVersion`
- `DBParameterGroups[].DBParameterGroupName`

AWS CLI の認証は利用者または実行基盤が提供する通常の AWS 認証情報を使う。スクリプトは `--profile` と `--region` を受け取れるようにするが、認証情報をファイルへ出力しない。

### 4-2. 移行カタログ

`config/migration-catalog.yml` は人が管理する正本である。RDS API では得られない対応関係と、8.4 側で人が決める値だけを記載する。

```yaml
environments:
  production:
    aws_region: ap-northeast-1
    migration_units:
      order-db-production:
        # RDS の DBInstanceIdentifier。インベントリと照合して情報を補完するキー。
        source_db_instance_identifier: shared-order-production-mysql80

        # 最終レビュー用の業務上の対応表。Blue/Green 実行スクリプトは参照しない。
        databases:
          - name: order
            applications: [order-api, order-batch]
          - name: payment
            applications: [payment-api]

        # 8.4 側の移行判断。パラメータグループは Phase 1 で別途作成済みであること。
        target:
          engine_version: "8.4.10"
          db_instance_class: db.r6g.large
          db_parameter_group_name: shared-order-production-mysql84-v1
          parameter_group_template_path: generated/parameter-groups/shared-order-production-mysql84.yaml
```

`migration_units` のキーは、生成先 `config/blue-green/<environment>.yml` の `services` キーになる。したがって、同一 RDS インスタンスを複数の移行単位に重複して書かない。

## 5. 生成処理

`generate_blue_green_config.py` は、移行カタログと RDS インベントリ JSON を読み込み、指定環境の `config/blue-green/<environment>.yml` を生成する。

生成する値は次のとおりである。

| 出力項目 | 取得元 |
|---|---|
| `environment`、`aws_region` | 移行カタログ |
| `source_db_instance_identifier` | 移行カタログ |
| `source_engine_version` | RDS インベントリの `EngineVersion` を `8.0` のような major.minor へ正規化 |
| `source_db_parameter_group_name` | RDS インベントリ |
| `target_engine_version`、`target_db_instance_class`、`target_db_parameter_group_name`、`target_parameter_group_template_path` | 移行カタログ |
| `protection_snapshot_identifier` | `<source_db_instance_identifier>-pre-bg` を生成 |
| `final_snapshot_identifier` | `<source_db_instance_identifier>-final` を生成 |
| `actions` | 常に `build`、`switchover`、`cleanup` を `pending` で生成 |

生成時に行う機械的な停止条件は最小限にする。

- カタログで指定した DB インスタンス ID がインベントリにない
- 対象インスタンスの `Engine` が `mysql` ではない
- 同じ環境内で一つの DB インスタンス ID が複数の移行単位に重複する
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

実装・変更時は、実環境の `staging`／`production` カタログ、AWS、既存の `config/blue-green/*.yml` をテスト対象にしない。

- テスト専用環境名は `test` とする。
- [migration-catalog.test.yml](examples/config-blue-green-generation/migration-catalog.test.yml) と [rds-instance-inventory.test.json](examples/config-blue-green-generation/rds-instance-inventory.test.json) をダミー入力として使う。
- [blue-green.test.expected.yml](examples/config-blue-green-generation/blue-green.test.expected.yml) を生成結果の期待値とし、生成 YAML を構文ではなくデータ構造として比較する。
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
