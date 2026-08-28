# CodeBuild / CodePipeline 実行定義

[codepipeline.yml](../examples/rds-blue-green-deployment/codepipeline.yml) は、サービス・環境ごとに CloudFormation で作成する CodePipeline と三つの CodeBuild プロジェクトを定義する。

```text
CodeConnections (GitHub) → BuildGreen → VerifyGreen → ManualApproval → Switchover
                             Step 3       Step 4          人の承認        Step 5
```

CodePipeline は `DetectChanges: false` のため、GitHub への push で自動開始しない。作業者は CloudFormation でスタックを作成後、`aws codepipeline start-pipeline-execution` または AWS Console から明示的に開始する。各サービス・環境には独立したスタックを作るが、実行するスクリプトと buildspec は共通である。

## 実行内容

| CodeBuild プロジェクト | buildspec | 既存スクリプト | 実行条件 |
|---|---|---|---|
| `BuildGreenProject` | `ci/codebuild/build-green.yml` | `scripts/build_green.sh` | `actions.build: approved` の場合だけ作成 |
| `VerifyGreenProject` | `ci/codebuild/verify-green.yml` | `scripts/verify_green.sh` | 常に AWS API 検証を実行 |
| `SwitchoverProject` | `ci/codebuild/switchover.yml` | `scripts/switchover.sh` | 手動承認済みかつ `actions.switchover: approved` の場合だけ切替 |

`VerifyGreenProject` の MySQL 実効値収集は `CollectMySqlRuntimeValues=false` が既定であり、Green DB へ接続しない。`true` を指定したスタックだけが、実行時に Secrets Manager から JSON の `username`／`password` を読み取り、MySQL 接続を行う。値を CodeBuild の通常環境変数へ保存せず、実行したシェルプロセス内だけで使用する。

Step 4 は最初に [Dockerfile.green-verification-report](../docker/Dockerfile.green-verification-report) をマルチステージビルドする。Go ビルドステージで作成した `generate_green_verification_report` だけを local exporter で `.tools/green-report/` に取り出し、`GREEN_REPORT_GENERATOR` として `verify_green.sh` に渡す。したがって CodeBuild の Step 4 プロジェクトだけは `PrivilegedMode: true` で Docker Buildx を使用する。Ruby ランタイムは CodeBuild に不要である。

各 buildspec は設定 YAML を読むために `PyYAML==6.0.2` を導入する。ローカルで Step 3・4・5 のシェルスクリプトを実行する場合も、事前に `python3 -m pip install 'PyYAML==6.0.2'` を一度実行する。

実効値収集を有効にする場合は、CodeBuild プロジェクトを RDS に到達できるネットワークに配置する必要がある。テンプレートには VPC・サブネット・セキュリティグループを組み込んでいないため、組織の既存ネットワーク方針に従い `VerifyGreenProject` に `VpcConfig` を追加する。あわせて CodeBuild 実行ロールに対象 secret の `secretsmanager:GetSecretValue` と、KMS カスタマー管理キーを使う場合は `kms:Decrypt` を許可する。

## デプロイ例

```bash
aws cloudformation deploy \
  --template-file examples/rds-blue-green-deployment/codepipeline.yml \
  --stack-name rds-bg-example-service-staging \
  --parameter-overrides \
    PipelineNamePrefix=rds-bg \
    EnvironmentName=staging \
    ServiceName=example-service \
    CodeStarConnectionArn=arn:aws:codeconnections:ap-northeast-1:123456789012:connection/xxxxxxxx \
    RepositoryId=your-org/your-repository \
    ArtifactBucketName=your-codepipeline-artifact-bucket \
    CodePipelineServiceRoleArn=arn:aws:iam::123456789012:role/CodePipelineRdsBlueGreen \
    CodeBuildServiceRoleArn=arn:aws:iam::123456789012:role/CodeBuildRdsBlueGreen

aws codepipeline start-pipeline-execution \
  --name rds-bg-staging-example-service
```

`CodeStarConnectionArn` は事前に GitHub と接続して `AVAILABLE` にした CodeConnections 接続を指定する。ロールはテンプレート外で管理し、最小権限で作成する。CodeBuild 実行ロールに必要な RDS 権限は [upgrade-flow-steps.md](../upgrade-flow-steps.md) の「CI 実行ロールに必要な権限」を参照する。
