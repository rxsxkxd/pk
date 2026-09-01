# RDS Blue/Green 用 CodeBuild / CodePipeline セットアップ手順

この文書は、[CodePipeline テンプレート](../examples/rds-blue-green-deployment/codepipeline.yml) を使い、RDS for MySQL 8.0 から 8.4 への Blue/Green 移行の Step 3・4・5 を AWS 上で実行するための準備・構築・運用手順である。

GitHub Actions は別の実行基盤としてそのまま維持する。本手順を適用しても GitHub Actions の定義や OIDC ロールは変更しない。

```text
CodeConnections（GitHub）
          │
          ▼
CodePipeline（サービス・環境ごとに 1 本）
          │
          ├─ BuildGreen    : Step 3、保護スナップショットと Green の構築
          ├─ VerifyGreen   : Step 4、構成・パラメータ・同期状態の検証
          ├─ ManualApproval: Step 4 の結果を人が確認
          └─ Switchover    : Step 5、Blue/Green 切替
```

各 CodeBuild はリポジトリ内の buildspec を使い、実処理は共通のシェルスクリプトを呼ぶ。

| Step | CodeBuild project | buildspec | 実行スクリプト |
|---|---|---|---|
| 3 | `BuildGreenProject` | `ci/codebuild/build-green.yml` | `scripts/build_green.sh` |
| 4 | `VerifyGreenProject` | `ci/codebuild/verify-green.yml` | `scripts/verify_green.sh` |
| 5 | `SwitchoverProject` | `ci/codebuild/switchover.yml` | `scripts/switchover.sh` |

## 0. CodeBuild の動作環境コンテナと追加導入物

AWS 上の 3 プロジェクトは、CloudFormation テンプレートで AWS 管理イメージ `aws/codebuild/standard:7.0` を指定する。このイメージは Ubuntu 22.04 の CodeBuild managed image である。AWS CLI を含む CodeBuild の標準ツール群はイメージ側のものを利用し、buildspec から AWS CLI を追加インストールしない。ローカルの CodeBuild Local Agent 用だけは、軽量な [Dockerfile.codebuild-runner](Dockerfile.codebuild-runner) を使用できる。AWS 上の CodeBuild image はこの代替 image に変更しない。

| Project | CodeBuild ベースイメージ | buildspec が選択・導入するもの | Docker 利用 | 実行する最終処理 |
|---|---|---|---|---|
| BuildGreen | `aws/codebuild/standard:7.0` | Python 3 と `PyYAML==6.0.2` | 不要、`PrivilegedMode: false` | シェルスクリプトと AWS CLI で Step 3 を実行 |
| VerifyGreen | `aws/codebuild/standard:7.0` | Python 3 と `PyYAML==6.0.2`。Go レポート生成器のビルド時だけ `golang:1.25` を pull | 必要、`PrivilegedMode: true` | CodeBuild コンテナ上で Go バイナリとシェルスクリプトを実行 |
| Switchover | `aws/codebuild/standard:7.0` | Python 3 と `PyYAML==6.0.2` | 不要、`PrivilegedMode: false` | シェルスクリプトと AWS CLI で Step 5 を実行 |

### 共通コンテナ

AWS 用と Local Agent 用で buildspec を分けないため、`runtime-versions` は指定しない。各 image に備わる `python3` を使用し、install フェーズで PyYAML の存在を確認する。

```bash
python3 -c 'import yaml' || python3 -m pip install --disable-pip-version-check 'PyYAML==6.0.2'
```

用途は、`scripts/build_green.sh`、`scripts/verify_green.sh`、`scripts/switchover.sh` と、その下位スクリプトが環境設定 YAML を読み取るためである。Ruby は CodeBuild のいずれのプロジェクトでも使用しない。AWS managed image では `standard:7.0` に含まれる Python 3 を、ローカル代替 image では Dockerfile で固定した Python 3.11 を使用する。

### VerifyGreen の Docker マルチステージビルド

VerifyGreen だけは、[Dockerfile.green-verification-report](Dockerfile.green-verification-report) を Docker Buildx でビルドする。

```text
aws/codebuild/standard:7.0（実行コンテナ）
  └─ docker buildx build
       ├─ builder: golang:1.25
       │    └─ gopkg.in/yaml.v3 v3.0.1 を取得して Go レポート生成器を静的ビルド
       └─ export: scratch
            └─ generate_green_verification_report バイナリだけを .tools/green-report/ に出力

aws/codebuild/standard:7.0（実行コンテナ）
  └─ verify_green.sh が上記バイナリを GREEN_REPORT_GENERATOR として実行
```

ビルド済み Docker イメージをレジストリへ push したり、最終ステージのコンテナを常駐起動したりはしない。Go バイナリを CodeBuild の作業ディレクトリへ取り出して実行するだけである。`PrivilegedMode: true` はこの Docker ビルドのためだけに VerifyGreen へ設定している。

そのため VerifyGreen は、CodeBuild managed image の取得先に加えて、`golang:1.25` の取得先と Go module の取得先へ到達できる必要がある。VPC 内で動かす場合は NAT gateway または組織で許可されたプロキシ・VPC endpoint を用意する。

### 任意の MySQL 実効値収集時だけ追加されるもの

`CollectMySqlRuntimeValues=true` の場合だけ、VerifyGreen は Secrets Manager から接続情報を取得し、`mysql` コマンドが見つからなければ次を実行する。

```bash
sudo apt-get update
sudo apt-get install -y mysql-client
```

したがって MySQL 接続をしない通常の Step 4 では、MySQL クライアントの導入も Green DB への接続も発生しない。ここで導入する `mysql-client` は Ubuntu の apt repository が提供するパッケージであり、現時点ではバージョン固定していない。MySQL クライアントの厳密なバージョン固定が必要になった場合は、`mysql:8.4.8` 等の固定イメージで実効値収集を行う方式へ変更してから有効化する。

## 1. 事前条件

次の情報・リソースを用意する。

| 項目 | 必要な情報または状態 | 用途 |
|---|---|---|
| ソースリポジトリ | GitHub の `owner/repository`、対象ブランチ | CodePipeline が buildspec・スクリプト・環境設定を取得する |
| CodeConnections 接続 | GitHub 接続済み・`AVAILABLE` の Connection ARN | Source ステージが GitHub を読む |
| S3 artifact bucket | 同一リージョンの既存バケット、暗号化・ライフサイクルを設定 | ソースと各 Step の成果物を保存する |
| CodePipeline 実行ロール | 既存 IAM role ARN | Pipeline が CodeConnections、S3、CodeBuild を利用する |
| CodeBuild 実行ロール | 既存 IAM role ARN | RDS・CloudWatch API と成果物を扱う |
| 環境設定 | `config/blue-green/<environment>.yml` の対象サービス定義 | Blue DB、8.4 PG、DB クラス、承認状態を決める |
| Step 2 完了 | MySQL 8.4 パラメータグループが CloudFormation で作成済み | Step 3 が `target_db_parameter_group_name` を RDS API へ渡す |

CodeConnections は、接続作成後に GitHub 側で認可を完了させる必要がある。Connection ARN は CloudFormation パラメータ `CodeStarConnectionArn` に渡す。[CodeConnections の GitHub 接続手順](https://docs.aws.amazon.com/dtconsole/latest/userguide/connections-create-github.html)を参照する。

artifact bucket は CodePipeline 実行リージョンに作成し、組織の要件に従い S3 バケット暗号化、パブリックアクセスブロック、保存期間を設定する。KMS カスタマー管理キーを使う場合は、後述の両 IAM ロールにそのキーの利用権限も必要となる。

## 2. IAM ロールと最小権限

テンプレートは IAM ロールを新規作成しない。既存ロール ARN を受け取るため、権限設計・信頼ポリシーは組織の IAM 管理に従って事前に作成する。

### CodePipeline 実行ロール

少なくとも次を許可する。

- artifact bucket に対する `s3:GetObject`、`s3:GetObjectVersion`、`s3:PutObject`、`s3:GetBucketVersioning`
- `codeconnections:UseConnection`（指定した Connection ARN のみ）
- 3 つの対象 CodeBuild project に対する `codebuild:StartBuild`、`codebuild:BatchGetBuilds`
- KMS CMK を artifact bucket に使う場合の `kms:Decrypt`、`kms:Encrypt`、`kms:GenerateDataKey`

### CodeBuild 実行ロール

共通の読み取り権限として、対象リージョンの `rds:DescribeDBInstances`、`rds:DescribeBlueGreenDeployments`、`rds:DescribeDBParameterGroups`、`rds:DescribeDBParameters`、`rds:DescribeDBSnapshots`、`cloudwatch:GetMetricStatistics` を許可する。

Step ごとの変更権限は次のとおりである。

| Project | 追加権限 | 用途 |
|---|---|---|
| BuildGreen | `rds:CreateDBSnapshot`、`rds:CreateBlueGreenDeployment` | 保護スナップショットと Green の作成 |
| VerifyGreen | なし | AWS API と RDS パラメータの読み取りだけ |
| Switchover | `rds:SwitchoverBlueGreenDeployment` | 承認後の切替 |

さらに CodeBuild の標準的な運用権限として、CloudWatch Logs のログ出力、artifact bucket の読み書き、KMS を使う場合の復号・暗号化を対象リソースに限定して許可する。RDS の変更 API は可能な範囲で対象 DB instance・snapshot・Blue/Green deployment の ARN に限定する。`Describe*` 系 API はリソースレベル制御ができない場合があるため、AWS IAM のサービス認可リファレンスで確認する。

## 3. Step 4 の実効値取得を有効にする場合だけ必要な設定

`CollectMySqlRuntimeValues` の既定値は `false` である。このままなら VerifyGreen は Green DB へ MySQL 接続せず、AWS API による検証だけを行う。

実効値もレポートへ載せる場合だけ、次を追加する。

1. Secrets Manager に JSON secret を作成する。キーは `username` と `password` とする。
2. `MySqlCredentialsSecretId` に secret ID または ARN を渡し、`CollectMySqlRuntimeValues=true` でスタックを更新する。
3. CodeBuild 実行ロールに、その secret だけの `secretsmanager:GetSecretValue` を許可する。CMK で暗号化した secret は `kms:Decrypt` も許可する。
4. `VerifyGreenProject` に、Green DB へ到達できる `VpcConfig`（VPC、private subnet、security group）を追加する。
5. MySQL ユーザーに `performance_schema.global_variables` を参照できる最小限の権限を与える。

テンプレートの VerifyGreenProject は Go レポート生成器の Docker マルチステージビルドのため `PrivilegedMode: true` である。VPC 内の CodeBuild から Docker Hub／Go module の取得、S3、CloudWatch Logs、AWS API に到達できるよう、NAT gateway または必要な VPC endpoint を用意する。これは `CollectMySqlRuntimeValues=false` でも Docker ビルドを使うため必要である。

## 4. CloudFormation での作成

サービス・環境ごとにスタックを一つ作成する。例えば `example-service` の staging は次のとおりである。

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
    BranchName=main \
    ArtifactBucketName=your-codepipeline-artifact-bucket \
    CodePipelineServiceRoleArn=arn:aws:iam::123456789012:role/CodePipelineRdsBlueGreen \
    CodeBuildServiceRoleArn=arn:aws:iam::123456789012:role/CodeBuildRdsBlueGreen
```

初回は `CollectMySqlRuntimeValues` と `MySqlCredentialsSecretId` を省略する。実効値取得を必要とするレビュー時だけ、ネットワーク・secret・権限を確認したうえで以下を追加してスタック更新する。

```text
CollectMySqlRuntimeValues=true
MySqlCredentialsSecretId=<対象の Secrets Manager secret ID または ARN>
```

CloudFormation の `CodeStarConnectionArn`、artifact bucket、両実行ロールはスタック外で管理する。テンプレートを削除しても、これら既存リソースは削除されない。

## 5. 実行手順

### 5-1. 実行前の確認

1. Step 1 の成立条件チェックと Step 2 のパラメータグループ作成・レビューを完了する。
2. 対象サービスの `config/blue-green/<environment>.yml` を確認する。
3. `source_db_instance_identifier`、`target_engine_version`、`target_db_instance_class`、`target_db_parameter_group_name`、`target_parameter_group_template_path` が正しいことを確認する。
4. Step 3 を許可する場合だけ `actions.build: approved` に変更し、通常の構成変更レビューを完了する。

### 5-2. Pipeline 開始と Step 3・4

本テンプレートでは `DetectChanges: false` のため、GitHub への push では自動開始しない。明示的に開始する。

```bash
aws codepipeline start-pipeline-execution \
  --name rds-bg-staging-example-service
```

BuildGreen は `actions.build: approved` かつ既存 Deployment がない場合だけ、保護スナップショットと Blue/Green deployment を作成する。既に存在する場合は冪等に成功する。VerifyGreen は以下を確認し、結果を `green-verification-report.md` として `VerifyGreenOutput` artifact に出力する。

- Green の MySQL バージョン、DB instance class、DB parameter group 関連付け、`in-sync`
- CloudFormation YAML の値と RDS parameter group `Source=user` の一致
- RDS `Source=system` と全パラメータ情報
- CloudWatch `ReplicaLag`
- 任意実行時だけ MySQL 実効値

### 5-3. 手動承認と Step 5

VerifyGreen の artifact と CloudWatch・アプリケーション検証の結果を確認する。切替を許可する場合だけ、構成ファイルの `actions.switchover: approved` をレビュー済みブランチへ反映する。

その後、CodePipeline Console の `ApproveSwitchover` ステージで承認する。ManualApproval と `actions.switchover: approved` の二つがそろわなければ、Switchover は実変更を行わない。`AVAILABLE` 以外の状態では `scripts/switchover.sh` が失敗するため、原因を確認してから再実行する。

## 6. 成果物・ログ・再実行

| 確認対象 | 確認場所 |
|---|---|
| 各 Step の標準出力・エラー | CodeBuild の CloudWatch Logs |
| AWS CLI 応答 JSON、Step 4 レポート | CodePipeline artifact bucket の `BuildGreenOutput`、`VerifyGreenOutput`、`SwitchoverOutput` |
| Pipeline 全体の実行履歴・手動承認 | CodePipeline Console または `get-pipeline-state` |
| Blue/Green 状態 | RDS Console または `describe-blue-green-deployments` |

実行をやり直す前に、設定ファイルの承認状態と RDS の実状態を確認する。BuildGreen は既存 deployment を検出して二重作成しない。Switchover は `AVAILABLE` の deployment だけを切り替える。設定を `pending` に戻しても、作成済み Green や切替済み DB を取り消す動作はしない。

## 7. 運用上の注意

- この Pipeline は Step 3・4・5 を対象にする。切替後の観測・旧 Blue の削除は別手順で管理する。
- `ManualApproval` は CodePipeline の承認であり、構成リポジトリの Pull Request 承認を置き換えない。`actions.switchover: approved` は構成変更レビューで管理する。
- RDS への変更権限は CodeBuild 実行ロールに集約し、通常の作業者に RDS API の直接変更権限を付与しない。
- `PrivilegedMode: true` は VerifyGreenProject の Docker ビルドにだけ必要である。BuildGreen と Switchover には設定しない。
- Step 4 の MySQL 実効値は YAML や `Source=user` と比較して合否を出す対象ではない。RDS の計算値・上限調整を含むため、人がレポートで判断する。

## 参考

- [AWS::CodePipeline::Pipeline CloudFormation リファレンス](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-codepipeline-pipeline.html)
- [AWS::CodeBuild::Project CloudFormation リファレンス](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-codebuild-project.html)
- [CodePipeline の CodeConnections source action](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodestarConnectionSource.html)
- [CodeBuild の buildspec リファレンス](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)
