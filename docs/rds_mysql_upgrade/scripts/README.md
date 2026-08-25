# Blue/Green 成立条件チェックの個別実行手順

[`collect_blue_green_prereqs.sh`](collect_blue_green_prereqs.sh) は、本書の手順を一括実行する収集スクリプトである。本書ではレビューや障害調査のために、各取得処理を個別に実行する方法を示す。

すべての `aws` コマンドは読み取り API（`Describe*`／`Get*`）だけを使用し、AWS リソースを変更しない。

## 0. 共通準備

```bash
export DB_INSTANCE_ID=<blue-instance-id>
export AWS_REGION=<region>
export AWS_PROFILE=<profile>
export TARGET_ENGINE_VERSION=8.4.9
export OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-prereqs.XXXXXX")
```

`--profile` を使わない場合は、各コマンドから `--profile "$AWS_PROFILE"` を除く。個別取得後に Ruby の一括評価を行う場合は、以下で示すファイル名のまま `OUTPUT_DIR` に保存する。

## 1. DB インスタンスの基本情報

対象: **0-1-01, 0-1-05, 0-1-07, 0-1-08, 0-1-10, 0-1-12, 0-1-14**

取得する情報: バックアップ保持期間、DB クラス、パラメータ／オプショングループ適用状態、RDS リードレプリカ構成、Secrets Manager 管理パスワード、IAM DB 認証。

```bash
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --output json > "$OUTPUT_DIR/db-instance.json"
```

確認する主なフィールド:

- `BackupRetentionPeriod`（0-1-01）
- `DBParameterGroups[].ParameterApplyStatus`（0-1-05）
- `ReadReplicaDBInstanceIdentifiers`（0-1-07, 0-1-12）
- `DBInstanceClass`（0-1-08）
- `ManageMasterUserPassword`／`MasterUserSecret`（0-1-10）
- `IAMDatabaseAuthenticationEnabled`（0-1-14）

## 2. 全 DB インスタンスのレプリカ親子関係

対象: **0-1-07**

取得する情報: 同一リージョン内の全 RDS DB インスタンスの `ReadReplica*` フィールド。対象 Blue の配下レプリカにさらに配下が存在するカスケード構成を確認する。

```bash
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" rds describe-db-instances \
  --output json > "$OUTPUT_DIR/all-db-instances.json"
```

## 3. `binlog_format` とパラメータグループ

対象: **0-1-02**

まず、手順 1 の出力から適用中の DB パラメータグループ名を取得する。

```bash
export PARAMETER_GROUP=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("DBInstances").first.fetch("DBParameterGroups").first.fetch("DBParameterGroupName")' "$OUTPUT_DIR/db-instance.json")

aws --region "$AWS_REGION" --profile "$AWS_PROFILE" rds describe-db-parameters \
  --db-parameter-group-name "$PARAMETER_GROUP" \
  --output json > "$OUTPUT_DIR/db-parameters.json"
```

`Parameters[]` から `ParameterName == binlog_format` の `ParameterValue` を記録する。RDS for MySQL の Blue/Green 作成で `ROW` は必須ではない。`MIXED`／`STATEMENT` の場合は、`ROW` 統一の必要性を通常のレプリケーション運用の方針として別途判断する。

## 4. オプショングループと `MEMCACHED`

対象: **0-1-03, 0-1-04**

まず、手順 1 の出力から適用中のオプショングループ名を取得する。

```bash
export OPTION_GROUP=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("DBInstances").first.fetch("OptionGroupMemberships").first.fetch("OptionGroupName")' "$OUTPUT_DIR/db-instance.json")

aws --region "$AWS_REGION" --profile "$AWS_PROFILE" rds describe-option-groups \
  --option-group-name "$OPTION_GROUP" \
  --output json > "$OUTPUT_DIR/option-group.json"
```

- 0-1-03: 手順 1 の `OptionGroupMemberships[].OptionGroupName` が `default:` で始まることを確認する。
- 0-1-04: `Options[].OptionName` に `MEMCACHED` が含まれないことを確認する。

## 5. 移行先 8.4 で利用可能なインスタンスクラス

対象: **0-1-08**

取得する情報: 指定した MySQL 8.4 パッチバージョンで作成可能な DB インスタンスクラス一覧。

```bash
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" rds describe-orderable-db-instance-options \
  --engine mysql \
  --engine-version "$TARGET_ENGINE_VERSION" \
  --output json > "$OUTPUT_DIR/orderable-classes.json"
```

手順 1 の `DBInstanceClass` が `OrderableDBInstanceOptions[].DBInstanceClass` に含まれることを確認する。

## 6. RDS Proxy と登録ターゲット

対象: **0-1-13**

取得する情報: リージョン内の RDS Proxy と、各 Proxy に登録されている DB ターゲット。対象 Blue の `DbiResourceId` がターゲットの `RdsResourceId` に含まれることを確認する。

```bash
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" rds describe-db-proxies \
  --output json > "$OUTPUT_DIR/db-proxies.json"

# Proxy ごとに実行する。出力ファイルの番号は任意だが Ruby 一括判定では 0 始まりの連番にする。
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" rds describe-db-proxy-targets \
  --db-proxy-name <db-proxy-name> \
  --output json > "$OUTPUT_DIR/db-proxy-targets-0.json"
```

Proxy が存在しない場合、ターゲット確認は不要である。Proxy が複数ある場合は、`db-proxy-targets-1.json`、`db-proxy-targets-2.json` のように追加する。

## 7. Zero-ETL 統合

対象: **0-1-11**

取得する情報: RDS Integration の `SourceArn` と `TargetArn`。対象 Blue の `DBInstanceArn` がどちらかに一致する統合を確認する。

```bash
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" rds describe-integrations \
  --output json > "$OUTPUT_DIR/integrations.json"
```

## 8. 空きストレージ

対象: **0-1-09**

取得する情報: CloudWatch の `AWS/RDS` 名前空間にある `FreeStorageSpace` の直近 1 時間の 5 分単位最小値（Byte）。

```bash
export START_TIME=$(ruby -rtime -e 'puts (Time.now.utc - 3600).iso8601')
export END_TIME=$(ruby -rtime -e 'puts Time.now.utc.iso8601')

aws --region "$AWS_REGION" --profile "$AWS_PROFILE" cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeStorageSpace \
  --dimensions "Name=DBInstanceIdentifier,Value=$DB_INSTANCE_ID" \
  --statistics Minimum \
  --period 300 \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --output json > "$OUTPUT_DIR/free-storage-space.json"
```

`Datapoints[].Minimum` の最小値が 2 GiB（`2147483648` Byte）以上を目安に確認する。

## 9. AWS CLI だけでは確認できない項目

対象: **0-1-06 外部 binlog レプリカ**

RDS API の読み取り結果だけでは、外部 MySQL をソースとする binlog レプリカかを確定できない。DB に接続できる権限を持つ担当者が、次を実行して結果が空であることを確認する。

```bash
mysql -h <blue-endpoint> -u <user> -p -e "SHOW REPLICA STATUS\G"
```

## 10. Ruby で一括判定する場合

手順 1〜8 の JSON を同じ `OUTPUT_DIR` に保存した後、収集メタデータを作成して判定する。

```bash
printf '{"db_instance_id":"%s","target_engine_version":"%s","collected_at":"%s"}\n' \
  "$DB_INSTANCE_ID" "$TARGET_ENGINE_VERSION" "$(ruby -rtime -e 'puts Time.now.utc.iso8601')" \
  > "$OUTPUT_DIR/metadata.json"

ruby scripts/evaluate_blue_green_prereqs.rb --input-dir "$OUTPUT_DIR"
```

`STOP` は Blue/Green 作成前に解消が必要な不適合、`REVIEW` は手動確認または対応方針の記録が必要な項目である。0-1-06 は常に `REVIEW` となるため、手順 9 の確認結果を作業証跡として残す。
