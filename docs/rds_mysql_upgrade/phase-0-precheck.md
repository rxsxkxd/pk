# Phase 0 — 0-1. Blue/Green の成立条件を確認

> 対象: Amazon RDS for MySQL 8.0.x から 8.4.x への Blue/Green Deployments を使ったメジャーアップグレード
>
> 目的: Blue/Green Deployments の作成リクエストが拒否される要因を、作成前にすべて解消する。

その他の Phase 0 項目（MyISAM の棚卸し、MySQL Shell の互換性チェック、SQL／クライアントライブラリの確認、インスタンスタイプの詳細検証）は、既存の[移行手順書](rds-mysql-84-migration-guide.md)を参照する。

## 実施方法

- 本チェックは Blue（現行の本番 DB インスタンス）に対して実施する。
- `[停止]` が 1 つでも残る場合、Blue/Green Deployments を作成しない。
- 各コマンドの出力を作業チケット等へ保存する。

## 成立条件チェックリスト

| No. | 状態 | 確認項目 | AWS 取得情報 | 合格条件／対応 |
|---|---|---|---|---|
| 0-1-01 | [停止] | 自動バックアップ | `describe-db-instances` の `BackupRetentionPeriod` | `1` 以上。`0` の場合は自動バックアップを有効化し、設定が反映されるまで待つ。 |
| 0-1-02 | [停止] | バイナリログ形式 | `describe-db-parameters` の `binlog_format` | `ROW`。`MIXED`／`STATEMENT` の場合は、Phase 1 でカスタムパラメータグループに `ROW` を設定する。 |
| 0-1-03 | [停止] | オプショングループ | `describe-db-instances` の `OptionGroupMemberships` | メジャーアップグレードの Blue/Green で使用可能なデフォルトのオプショングループを使用する。カスタムグループを使っている場合は、デフォルトへ戻す影響を確認・解消する。 |
| 0-1-04 | [停止] | memcached | `describe-option-groups` の `Options[].OptionName` | `MEMCACHED` がないこと。ある場合は利用停止・アプリ設定変更・オプショングループ変更を先に完了する。 |
| 0-1-05 | [停止] | パラメータ適用状態 | `describe-db-instances` の `DBParameterGroups[].ParameterApplyStatus` | `in-sync`。`pending-reboot` 等の場合は、必要なパラメータ反映を完了する。 |
| 0-1-06 | [停止] | 外部 binlog レプリカ | AWS API では確認不可。MySQL の `SHOW REPLICA STATUS\G` | 結果が空であること。外部レプリカの場合は構成解消または移行方式を再検討する。 |
| 0-1-07 | [停止] | カスケードリードレプリカ | `describe-db-instances` の `ReadReplica*` 親子関係 | カスケード構成がないこと。該当する場合は構成を解消する。 |
| 0-1-08 | [停止] | インスタンスクラスの世代 | `describe-db-instances` の `DBInstanceClass`、`describe-orderable-db-instance-options` | MySQL 8.4 を作成可能な current/latest-generation クラスであること。前世代クラスは、Blue/Green 作成前にクラス変更を完了する。 |
| 0-1-09 | [要判断] | 空きストレージ | `get-metric-statistics` の `AWS/RDS:FreeStorageSpace` | アップグレード・検証中に逼迫しない余裕があること（目安: 2 GiB 以上）。不足時は空き容量を確保する。 |
| 0-1-10 | [要判断] | Secrets Manager 管理パスワード | `describe-db-instances` の `ManageMasterUserPassword`／`MasterUserSecret` | 利用中なら、Blue/Green の制約と一時解除・再設定の手順を確認済み。 |
| 0-1-11 | [要判断] | Zero-ETL 統合 | `describe-integrations` の `SourceArn`／`TargetArn` | 利用中なら、Blue/Green の制約と一時解除・再設定の手順を確認済み。 |
| 0-1-12 | [要判断] | クロスリージョンリードレプリカ | `describe-db-instances` の `ReadReplicaDBInstanceIdentifiers` | 利用中なら、Blue/Green の制約と一時解除・再設定の手順を確認済み。 |
| 0-1-13 | [要判断] | RDS Proxy | `describe-db-proxies`、`describe-db-proxy-targets` の `RdsResourceId` | 利用時は Blue が事前に対象 Proxy へ登録済みであること。Blue/Green 作成後に新規登録できない制約を関係者が認識していること。 |
| 0-1-14 | [要判断] | IAM DB 認証 | `describe-db-instances` の `IAMDatabaseAuthenticationEnabled` | 利用時は、切替後の Green 接続用 DB リソース ID／ARN を IAM ポリシーに追加する手順と権限が準備済み。 |

## 確認コマンド

### 自動チェック（推奨）

収集は AWS CLI の読み取り API（`Describe*`／`Get*`）だけで行い、判定は AWS API を呼ばない Ruby スクリプトで行う。収集スクリプト内では、各 AWS CLI コマンドの直前に「何を取得し、どの成立条件の判定に使うか」をコメントで明記している。

個別の AWS CLI コマンドを実行する場合は、[個別実行手順](scripts/README.md)を参照する。

```bash
# 1. AWS の情報を一時ディレクトリへ収集する（変更操作なし）
bash scripts/collect_blue_green_prereqs.sh \
  --db-instance-id <blue-instance-id> \
  --region <region> \
  --profile <profile>

# 2. 前コマンドが表示した一時ディレクトリを指定して、ローカルで判定する
ruby scripts/evaluate_blue_green_prereqs.rb \
  --input-dir <collector-output-dir>
```

判定結果の `STOP` は Blue/Green 作成前に解消が必要な不適合、`REVIEW` は利用状況と対応手順の確認が必要な項目を表す。判定スクリプトは `STOP` がある場合に終了コード `1` を返すため、CI 等でも利用できる。

### 個別確認

```bash
# インスタンスの基本設定・成立条件をまとめて確認
aws rds describe-db-instances \
  --db-instance-identifier <blue-instance-id> \
  --query 'DBInstances[0].{Id:DBInstanceIdentifier,Arn:DBInstanceArn,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,BackupRetention:BackupRetentionPeriod,ParameterGroups:DBParameterGroups,OptionGroups:OptionGroupMemberships,ReadReplicaSource:ReadReplicaSourceDBInstanceIdentifier,ReadReplicas:ReadReplicaDBInstanceIdentifiers}' \
  --output json

# 実効値を確認
mysql -h <blue-endpoint> -u <user> -p -e "SHOW VARIABLES LIKE 'binlog_format';"

# 外部 binlog レプリカでないことを確認（通常、結果が空なら問題なし）
mysql -h <blue-endpoint> -u <user> -p -e "SHOW REPLICA STATUS\G"

# オプショングループの詳細と MEMCACHED の有無を確認
aws rds describe-option-groups \
  --option-group-name <current-option-group> \
  --query 'OptionGroupsList[0].{Name:OptionGroupName,Engine:EngineName,MajorEngineVersion:MajorEngineVersion,Options:Options[*].OptionName}' \
  --output json

# 空き容量の直近値を確認（値は Byte）
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value=<blue-instance-id> \
  --statistics Minimum --period 300 \
  --start-time <utc-start-time> --end-time <utc-end-time> \
  --output table
```

## 完了判定

- [ ] `[停止]` の項目がすべて合格している。
- [ ] `[要判断]` の利用有無・影響・対応手順が記録されている。
- [ ] 確認コマンドの出力を証跡として保存している。
- [ ] 不適合項目の是正作業と、再確認の担当者・期限が決まっている。

## 参考

- [Amazon RDS Blue/Green Deployments の概要](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments.html)
- [RDS for MySQL のメジャーバージョンアップグレード](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.MySQL.Major.html)
