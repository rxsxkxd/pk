# オペレーション編 1／2: 環境構築（CloudFormation）

移行を実行するための**土台を一度だけ作る**手順。ここで作ったパイプラインを使って実際の移行を進める手順は [オペレーション編 2／2: 移行の実行](operations-migration-run.md) にある。

```text
【本書】環境構築            →  【編 2】移行の実行
  一度だけ                        移行対象ごと・環境ごとに繰り返す
  CloudFormation でパイプラインを作る   そのパイプラインで Blue/Green 移行を回す
```

**本書は AWS リソースを作る。**RDS には触れないが、IAM ロール・CodeBuild・CodePipeline・S3 を作成する。

## 1. 作られるもの・作られないもの

テンプレートは `examples/rds-blue-green-deployment/codepipeline-all-in-one.yml` を使う。

| | 内容 |
|---|---|
| **作る** | S3 バケット 1（省略時）とバケットポリシー、IAM ロール 7（CodeBuild 用 6 + CodePipeline 用 1）とマネージドポリシー 1、CodeBuild プロジェクト 6、CodePipeline 1 |
| **作らない** | **RDS リソース**、セキュリティグループ、VPC・subnet、SSM パラメータ、CodeConnections の接続、KMS キー |

**RDS を一切作らないことが重要である。**このスタックを作っても壊しても、DB には影響しない。

> IAM ロールを組織で一元管理している場合は `codepipeline.yml`（既存ロールと既存バケットを受け取る版）を使う。本書は all-in-one 版を前提とする。

## 2. 事前に用意するもの

**スタックを作る前に人が用意する必要があるもの**を先に挙げる。どれもテンプレートは作らない。

| # | 用意するもの | 必須か | 確認方法 |
|---|---|---|---|
| 1 | ソースリポジトリ（GitHub または CodeCommit） | **必須** | — |
| 2 | CodeConnections の接続（GitHub の場合） | GitHub なら必須 | 状態が `AVAILABLE` であること |
| 3 | 移行元 DB の拡張モニタリングのロール名 | 使っていれば必須 | 下記 2-3 |
| 4 | SSM Parameter Store の SecureString 2 本 | MySQL 実効値を収集する場合だけ | 下記 2-4 |
| 5 | VPC・private subnet・セキュリティグループ | 同上 | 下記 2-5 |

### 2-1. ソースリポジトリ

`SourceProvider` で選ぶ。

| 値 | 使うパラメータ |
|---|---|
| `CodeConnections`（既定） | `CodeStarConnectionArn`、`RepositoryId` |
| `CodeCommit` | `CodeCommitRepositoryName` |

**どちらも push では自動起動しない。**作業者が明示的に開始する設計である。

### 2-2. CodeConnections の接続（GitHub の場合）

接続を作ったあと、GitHub 側で認可を完了させる必要がある。**`PENDING` のままでは Source ステージが失敗する。**

```bash
aws codestar-connections list-connections \
  --query 'Connections[].[ConnectionName,ConnectionStatus,ConnectionArn]' --output table
```

`ConnectionStatus` が `AVAILABLE` であることを確認する。手順は [CodeConnections の GitHub 接続](https://docs.aws.amazon.com/dtconsole/latest/userguide/connections-create-github.html) を参照する。

### 2-3. 拡張モニタリングのロール名

移行元 DB で拡張モニタリング（Enhanced Monitoring）が有効だと、**Blue/Green 作成時に RDS が Green へその設定をコピーする。**このときロールを渡す権限（`iam:PassRole`）が必要になる。

```bash
aws rds describe-db-instances --db-instance-identifier <blue-id> \
  --query 'DBInstances[0].[MonitoringInterval,MonitoringRoleArn]'
```

`MonitoringInterval` が `0` 以外なら有効である。`MonitoringRoleArn` の**ロール名部分**を `RdsMonitoringRoleName` に渡す（既定は `rds-monitoring-role`）。

**これを誤ると Step 3 が `AccessDenied` で失敗する。**使っていなければ空文字にする。

### 2-4. SSM Parameter Store（MySQL 実効値を収集する場合だけ）

**サービスごとに 2 本**（パスワードとユーザー名）を SecureString で作る。

```bash
aws ssm put-parameter --type SecureString \
  --name /rds-bg/staging/example-service/mysql/password --value '<パスワード>'
aws ssm put-parameter --type SecureString \
  --name /rds-bg/staging/example-service/mysql/user --value '<ユーザー名>'
```

**ユーザー名も秘匿側へ置く。**設定ファイルには名前だけを書き、値は書かない。

**環境ごとに 1 つの階層（例 `/rds-bg/staging`）の下へまとめて置く。**スタックには階層だけを渡し（`MySqlCredentialsParameterPath=/rds-bg/staging`）、VerifyGreen はその配下を読めるようになる。サービスを増やしても同じ階層に置けばスタックの更新は要らない。**この階層には移行作業用のパラメータだけを置く**（配下すべてが読めるため）。

暗号化キーは **AWS 管理キー（`alias/aws/ssm`）を前提**とする。カスタマー管理キーなら `MySqlCredentialsKmsKeyArn` も渡す。

MySQL ユーザーには `performance_schema.global_variables` を読める最小権限だけを与える。

### 2-5. ネットワーク（MySQL 実効値を収集する場合だけ）

**VPC 内へ入れるのは `VerifyGreen` だけである。**他の 6 プロジェクトは VPC 外で動く。

| 用意するもの | 要件 |
|---|---|
| private subnet（2 アベイラビリティゾーン以上を推奨） | **RDS へ到達できること。外部への経路は置かない** |
| セキュリティグループ | **テンプレートは作らない。**別途用意する |
| VPC endpoint | `s3`（Gateway）、`logs` / `rds` / `monitoring` / `ssm`（Interface） |

SG の具体的な作り方は [VerifyGreen のセキュリティグループ設定](ci/verify-green-security-group-setup.md)、構成の背景は [Step 4 の分離と VPC 配置](ci/verify-green-vpc-architecture.md) にある。

> **`kms` の VPC endpoint は要らない。**SecureString の復号は SSM 側で行われ、ビルドコンテナが KMS を直接呼ぶことはない。

## 3. スタックを作る

**最小構成**（MySQL 実効値の収集をしない場合）はこれで足りる。

```bash
aws cloudformation deploy \
  --template-file examples/rds-blue-green-deployment/codepipeline-all-in-one.yml \
  --stack-name rds-bg-staging \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName=staging \
    DefaultServiceName=example-service \
    CodeStarConnectionArn=arn:aws:codeconnections:ap-northeast-1:123456789012:connection/xxxxxxxx \
    RepositoryId=your-org/your-repository \
    "ProtectedRdsResourceArns=arn:aws:rds:ap-northeast-1:123456789012:db:example-service-staging*,arn:aws:rds:ap-northeast-1:123456789012:snapshot:example-service-staging*" \
    RdsMonitoringRoleName=rds-monitoring-role
```

`--capabilities CAPABILITY_NAMED_IAM` は必須である（IAM ロールを**名前付きで**作るため、`CAPABILITY_IAM` では足りない）。

**全パラメータの一覧・MySQL 実効値収集を有効にする場合の指定・パラメータファイル方式・更新と削除**は [パイプラインのデプロイとパラメータ一覧](ci/codepipeline-all-in-one-parameters.md) にまとめてある。

### 特に誤りやすい 2 つ

| パラメータ | 誤ると |
|---|---|
| `ProtectedRdsResourceArns` | **空のままだとアカウント・リージョン内の全 DB が変更権限の対象になる。**必ず絞る。`db` と `snapshot` の**両方**を入れる（片方だけだとスナップショット作成が失敗する） |
| `RdsMonitoringRoleName` | 実際のロール名と違うと Step 3 が `iam:PassRole` の `AccessDenied` で失敗する |

## 4. 作成後の確認

```bash
aws cloudformation describe-stacks --stack-name rds-bg-staging \
  --query 'Stacks[0].Outputs' --output table
```

| 出力 | 用途 |
|---|---|
| `ArtifactBucket` | 使用しているアーティファクト用バケット（自動作成した場合もここに出る） |
| `PipelineName` | 次の編で使うパイプライン名 |
| `StartCommand` | パイプラインを開始するコマンド（そのまま実行できる） |

### スタック作成直後にパイプラインが 1 回動く

**CodePipeline は作成時に 1 回だけ自動実行される。**これは AWS の仕様で、`DetectChanges: false` は push による起動を止めるだけである。

この 1 回目は**何も壊さない**。設定ファイルの `actions` がすべて `pending` なら、Step 3・5・7 は何もせず正常終了する。承認宣言が安全弁として働く設計になっている。

## 5. 更新と削除

### 更新

```bash
aws cloudformation deploy ... --parameter-overrides <変更後の全パラメータ>
```

**`deploy` で省略したパラメータは既定値へ戻る。**前回値は引き継がれない。現在値はこれで確認する。

```bash
aws cloudformation describe-stacks --stack-name rds-bg-staging \
  --query 'Stacks[0].Parameters' --output table
```

### 削除

```bash
aws cloudformation delete-stack --stack-name rds-bg-staging
```

| | 削除されるか |
|---|---|
| IAM ロール・CodeBuild・CodePipeline | **される** |
| 自動作成した S3 バケット | **されない**（`DeletionPolicy: Retain`。中身があると S3 は削除できずスタック削除が失敗するため） |
| **RDS リソース** | **一切影響しない** |

## 6. ローカルで先に確かめる（任意）

AWS へデプロイする前に、buildspec がローカルで通ることを確認できる。

| 確認したいもの | 手順 |
|---|---|
| Go のビルド（`BuildReportTool`） | [BuildReportTool のローカル検証](ci/build-report-tool-local-verification.md) |
| 各フローの buildspec | [CodeBuild 各フローの単体ローカル検証](ci/codebuild-local-verification.md) |

## 次にやること

環境ができたら [オペレーション編 2／2: 移行の実行](operations-migration-run.md) へ進む。

## 補足リファレンス

本書は手順に絞ってある。背景や詳細は次を参照する。

| 知りたいこと | ドキュメント |
|---|---|
| 全パラメータの意味と指定例 | [ci/codepipeline-all-in-one-parameters.md](ci/codepipeline-all-in-one-parameters.md) |
| パイプラインの構造（ステージ・IAM・artifact） | [ci/codepipeline-structure.md](ci/codepipeline-structure.md) |
| 前提条件と設計上の判断 | [ci/codebuild-codepipeline-setup.md](ci/codebuild-codepipeline-setup.md) |
| VerifyGreen の VPC 配置 | [ci/verify-green-vpc-architecture.md](ci/verify-green-vpc-architecture.md) |
| セキュリティグループの作り方 | [ci/verify-green-security-group-setup.md](ci/verify-green-security-group-setup.md) |
| CI から出ていく通信先 | [ci/codebuild-remote-external-access.md](ci/codebuild-remote-external-access.md) |
| Go ビルドが失敗したとき | [ci/build-report-tool-troubleshooting.md](ci/build-report-tool-troubleshooting.md) |
