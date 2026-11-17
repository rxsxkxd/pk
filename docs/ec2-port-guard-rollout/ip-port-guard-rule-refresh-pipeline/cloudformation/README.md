# CloudFormation YAML の2スタック

このフォルダの親（`ip-port-guard-rule-refresh-pipeline/`）で実行する。[バケット用](rule-buckets.yml)を先に作り、その出力を[パイプライン用](list-refresh-pipeline.yml)へ渡す。バケットは環境間で共用し、パイプラインは環境ごとに作る。ここにあるコマンドは手順であり、実際の AWS への作成は未実施。

## 1. バケット用スタック

```bash
export AWS_REGION=ap-northeast-1
export AWS_PROFILE=your-profile

aws --region "$AWS_REGION" --profile "$AWS_PROFILE" cloudformation deploy \
  --stack-name port-guard-rule-buckets \
  --template-file cloudformation/rule-buckets.yml
```

既定では、`ip-port-guard-pipeline-<アカウント ID>-<リージョン>-an` を中間成果物用に作る。ルール用の `ip-port-guard-rules-<アカウント ID>-<リージョン>-an` は作成済みのものを参照する。既存バケットの設定は変更しない。

| パラメータ | 既定値 | 用途 |
|---|---|---|
| `PipelineBucketNamePrefix` | `ip-port-guard-pipeline` | 作る中間成果物用バケット名の先頭部分 |
| `CreatePublishBucket` | `false` | 別のアカウントなどでルール用バケットを新規作成するときだけ `true` にする |
| `PublishBucketName` | 空 | 既存ルール用バケットの完全名。空なら名前空間の接尾辞を含む既定名を使う。新規作成時は使わない |

新規作成するバケットは、アカウントのリージョナル名前空間・バージョニング有効・SSE-S3 暗号化・パブリックアクセス全ブロック・ACL 無効。スタック削除や置き換えでもバケットは保持する。中間成果物用バケットの古いバージョンは90日で削除する。

## 2. パイプライン用スタック

CodeConnections でリポジトリへの接続を作り、認可を完了させた `AVAILABLE` の接続 ARN を使う。接続・バケット・パイプラインは同じアカウント・リージョンで使う。CodeConnections を使えるリージョンを選ぶ（この手順は東京リージョンを例にしている）。

```bash
PIPELINE_BUCKET=$(aws --region "$AWS_REGION" --profile "$AWS_PROFILE" cloudformation describe-stacks \
  --stack-name port-guard-rule-buckets \
  --query "Stacks[0].Outputs[?OutputKey=='PipelineBucketName'].OutputValue | [0]" --output text)
PUBLISH_BUCKET=$(aws --region "$AWS_REGION" --profile "$AWS_PROFILE" cloudformation describe-stacks \
  --stack-name port-guard-rule-buckets \
  --query "Stacks[0].Outputs[?OutputKey=='PublishBucketName'].OutputValue | [0]" --output text)

# 実際の接続・リポジトリに置き換える
CONNECTION_ARN=arn:aws:codeconnections:ap-northeast-1:111122223333:connection/your-connection-id
REPOSITORY_ID=your-owner/your-repository
SOURCE_DIRECTORY=docs/ec2-port-guard-rollout/ip-port-guard-rule-refresh-pipeline

aws --region "$AWS_REGION" --profile "$AWS_PROFILE" cloudformation deploy \
  --stack-name port-guard-list-refresh-staging \
  --template-file cloudformation/list-refresh-pipeline.yml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    EnvironmentName=staging \
    PipelineBucketName="$PIPELINE_BUCKET" PublishBucketName="$PUBLISH_BUCKET" \
    ConnectionArn="$CONNECTION_ARN" FullRepositoryId="$REPOSITORY_ID" \
    BranchName=main SourceDirectory="$SOURCE_DIRECTORY" RequireApproval=true
```

このプロジェクトをリポジトリ直下に置いているなら `SOURCE_DIRECTORY=.` にする。`allow-lists/<環境>/` は同じソースから読み込む。独自の ZIP 作成やスクリプトの S3 への事前配置は不要。

| パラメータ | 既定値・指定するもの |
|---|---|
| `EnvironmentName` | 必須。`development`・`staging`・`production` |
| `PipelineBucketName` | 必須。バケット用スタックの同名出力 |
| `PublishBucketName` | 必須。バケット用スタックの同名出力 |
| `ConnectionArn` | 必須。認可済み CodeConnections 接続 ARN |
| `FullRepositoryId` | 必須。大文字・小文字も含めた `owner/repository` |
| `BranchName` | `main` |
| `SourceDirectory` | `.`。リポジトリ直下を基準としたプロジェクトの場所 |
| `RequireApproval` | `true`。`false` なら承認ステージを省略 |
| `LogRetentionInDays` | `90` |

既存のルール用バケットには SSE-S3 を想定している。SSE-KMS のバケットを使う場合は、使用するキーへの権限とキーポリシーの追加が別途必要になる。

## 3. 開始と承認

```bash
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" codepipeline start-pipeline-execution \
  --name port-guard-list-refresh-staging

# 増減を確認したうえで 5% の判定を通すとき
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" codepipeline start-pipeline-execution \
  --name port-guard-list-refresh-staging --variables name=FORCE,value=1
```

ビルドログの件数・増減を確認し、CodePipeline のコンソールから承認する。後段は、承認したビルドの成果物に含まれる `deploy-rules.sh` と `work/<環境>/` を使う。Git の最新内容を取り直して作り直すことはしない。

ソース変更による自動開始は無効。パイプラインを初めて作成する際の初回実行は発生し得る。`QUEUED` はこのパイプライン内の実行を直列にするが、ローカルでの実行とは排他しない。

## 検証

```bash
cfn-lint cloudformation/rule-buckets.yml cloudformation/list-refresh-pipeline.yml
```

CDK と共通の動作・権限・模擬実行テストは [CDK の README](../cdk/python/README.md) を参照する。

仕様を確認した公式資料（2026-11-17）: [S3 バケットの CloudFormation 定義](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-s3-bucket.html)、[CodeConnections の設定と必要な権限](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodestarConnectionSource.html)、[パイプラインの成果物用権限](https://docs.aws.amazon.com/codepipeline/latest/userguide/how-to-custom-role.html)、[CodeBuild の buildspec と成果物](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)。
