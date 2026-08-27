# RDS for MySQL Blue/Green 構築対象一覧

このファイルは `config/rds-blue-green-deployment-targets.yml` を基に、今回 CloudFormation YAML を生成したサービスの構築対象を一覧化したものである。
移行元 DB の情報は、事前に読み取り専用の `aws rds describe-db-instances` で収集した `all-db-instances.json` の取得結果である。

## 構築対象と設定

| サービス | 環境 | 移行元 DB インスタンス | 移行元 ARN | 移行元エンジン | 移行元インスタンスタイプ | 移行元パラメータグループ | Green インスタンスタイプ | MySQL 8.4 パラメータグループ Export | 生成テンプレート |
|---|---|---|---|---|---|---|---|---|---|
| example-service | production | example-service-production-mysql80 | arn:aws:rds:ap-northeast-1:123456789012:db:example-service-production-mysql80 | mysql 8.0.41 | db.r6g.large | example-service-production-mysql80-parameter-group | db.r6g.large | example-service-production-mysql84-parameter-group-DBParameterGroupName | examples/rds-blue-green-deployment/output/example-service-blue-green-deployment.yaml |
| example-service | staging | example-service-staging-mysql80 | arn:aws:rds:ap-northeast-1:123456789012:db:example-service-staging-mysql80 | mysql 8.0.41 | db.t4g.medium | example-service-staging-mysql80-parameter-group | db.t4g.medium | example-service-staging-mysql84-parameter-group-DBParameterGroupName | examples/rds-blue-green-deployment/output/example-service-blue-green-deployment.yaml |

## 実行時に指定する値

- `BlueGreenDeploymentProviderServiceToken`: `CreateBlueGreenDeployment` を実行するカスタムリソースプロバイダーの ARN。
- `BlueGreenDeploymentName`: RDS 上で一意な Blue/Green Deployment 名。
- `TargetEngineVersion`: 対象リージョンでサポートされる MySQL 8.4 の目標バージョン。

## 留意事項

- CloudFormation に RDS Blue/Green Deployment のネイティブリソースはないため、生成テンプレートはカスタムリソースを使用する。
- switchover はこの生成対象に含めない。構築後の検証・承認を経た独立操作として実施する。
