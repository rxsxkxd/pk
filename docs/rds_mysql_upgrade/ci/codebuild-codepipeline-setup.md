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
| 4 | `BuildReportToolProject` | `ci/codebuild/build-report-tool.yml` | — （Go レポート生成器のビルドのみ） |
| 4 | `VerifyGreenProject` | `ci/codebuild/verify-green.yml` | `scripts/verify_green.sh` |
| 5 | `SwitchoverProject` | `ci/codebuild/switchover.yml` | `scripts/switchover.sh` |

## 0. CodeBuild の動作環境コンテナと追加導入物

AWS 上の 3 プロジェクトは、CloudFormation テンプレートで AWS 管理イメージ `aws/codebuild/standard:7.0` を指定する。このイメージは Ubuntu 22.04 の CodeBuild managed image である。AWS CLI を含む CodeBuild の標準ツール群はイメージ側のものを利用し、buildspec から AWS CLI を追加インストールしない。ローカルの CodeBuild Local Agent 用だけは、軽量な [Dockerfile.codebuild-runner](Dockerfile.codebuild-runner) を使用できる。AWS 上の CodeBuild image はこの代替 image に変更しない。

| Project | CodeBuild ベースイメージ | buildspec が選択・導入するもの | Docker 利用 | 実行する最終処理 |
|---|---|---|---|---|
| BuildGreen | `aws/codebuild/standard:7.0` | `rbenv local 3.4.10` で Ruby を選ぶ（jq は image 同梱） | 不要、`PrivilegedMode: false` | シェルスクリプトと AWS CLI で Step 3 を実行 |
| VerifyGreen | `aws/codebuild/standard:7.0` | `rbenv local 3.4.10` と `runtime-versions: golang: 1.25`（jq は image 同梱） | 不要、`PrivilegedMode: false` | 同一イメージ内で Go バイナリをビルドし、シェルスクリプトと共に実行 |
| Switchover | `aws/codebuild/standard:7.0` | `rbenv local 3.4.10` で Ruby を選ぶ（jq は image 同梱） | 不要、`PrivilegedMode: false` | シェルスクリプトと AWS CLI で Step 5 を実行 |

### 共通コンテナ

AWS 用と Local Agent 用で buildspec を分けない。**設定 YAML の読み取りに使う Ruby は、CodeBuild image に同梱の rbenv で選ぶ。**`runtime-versions` では指定しない。

```yaml
  install:
    commands:
      - if command -v rbenv >/dev/null 2>&1; then rbenv local 3.4.10; fi
      - ruby --version
```

`rbenv` が無い環境（Local Agent 用のランナー image は Ruby を固定済み）では何もしない。YAML / JSON は Ruby の標準ライブラリなので、install フェーズでのパッケージ導入は無い（PyPI へも到達しない）。

**`rbenv local` は cwd（`CODEBUILD_SRC_DIR`）へ `.ruby-version` を書く。**ローカルで buildspec を試すと作業ツリーにこのファイルが残るため `.gitignore` 済みである。ファイルを作らせたくない場合は `export RBENV_VERSION=3.4.10` でも同じ効果になる。

VerifyGreen だけは `runtime-versions: golang: 1.25` を指定する。Docker を使わずに Go レポート生成器を同一イメージ内でビルドするためである。

> **指定したバージョンが image に無ければ、`rbenv local` はその場で失敗する**（`rbenv: version '3.4.10' not installed`）。別の Ruby で黙って動くより安全側である。利用できる版は `rbenv versions` で確認する。`golang: 1.25` が解決できない場合は、より新しい CodeBuild image を選ぶか、`go.mod` の `go` ディレクティブを image が提供するバージョンへ下げる。

```bash
ruby --version   # YAML / JSON は標準ライブラリなので追加導入は無い
```

用途は、`scripts/build_green.sh`、`scripts/verify_green.sh`、`scripts/switchover.sh` と、その下位スクリプトが環境設定 YAML を読み取るためである。Ruby は CodeBuild のいずれのプロジェクトでも使用しない。AWS managed image では `standard:7.0` に含まれる Python 3 を、ローカル代替 image では Dockerfile で固定した Python 3.11 を使用する。

### VerifyGreen の Go レポート生成器

VerifyGreen だけは Go バイナリを使う。**Docker は使わず、ビルドと実行を別の buildspec に分けている。**

```text
ci/codebuild/build-report-tool.yml   ← ビルドだけ。AWS を呼ばない
  ├─ install:  runtime-versions: golang: 1.25
  └─ build:    CGO_ENABLED=0 go build ... -o .tools/green-report/... ./scripts
               → artifact: .tools/green-report/generate_green_verification_report

ci/codebuild/verify-green.yml        ← 実行だけ。Go を使わない
  ├─ pre_build: CODEBUILD_SRC_DIR_ReportToolOutput から上記バイナリを受け取る
  │             （受け取れなければ明示エラーで停止する。ここではビルドしない）
  └─ build:     verify_green.sh が実行
```

**分けた理由**は、VerifyGreen が Green DB へ到達するため VPC 内へ配置される可能性があり、その経路に Go module の取得（`proxy.golang.org`）を持ち込みたくないためである。

| プロジェクト | 外部ネットワーク | AWS API | VPC 配置 |
|---|---|---|---|
| `BuildReportToolProject` | **必要**（Go module の取得） | 呼ばない | 不要 |
| `VerifyGreenProject` | **不要** | 読み取りのみ | Green DB へ接続する場合だけ必要 |

CodePipeline は `BuildReportTool` ステージの出力 artifact（`ReportToolOutput`）を `VerifyGreen` の 2 つ目の input artifact として渡す。入力が複数になるため、アクションの `Configuration` に `PrimarySource: SourceOutput` を指定して、どちらをソースとして展開するかを明示している。2 つ目の artifact は `CODEBUILD_SRC_DIR_ReportToolOutput` に展開される。

> **`verify-green.yml` はレポート生成器をビルドしない。**artifact を受け取れない場合は、理由と対処（`build-report-tool.yml` を実行して artifact を渡す、または `GREEN_REPORT_GENERATOR` に既存バイナリを指定する）を出して停止する。外部へ出ないという前提を崩さないためである。

**`PrivilegedMode` はどのプロジェクトにも設定しない。**

**Go module の取得先（`proxy.golang.org`）へ到達する必要があるのは `BuildReportToolProject` だけである。**イメージが提供する Go が `go.mod` の要求（`go 1.25`）より古い場合は、`GOTOOLCHAIN=auto`（Go 1.21 以降の既定。buildspec で明示している）が必要なツールチェーンを取得するため、その経路も要る。このプロジェクトは VPC 設定を与えないので、VPC 内の経路整備は不要である。

### VerifyGreen を RDS のある VPC 内で実行する

> 構成の全体像と、どこで落ちるかの一覧は [Step 4 の分離と VPC 配置](verify-green-vpc-architecture.md) に図でまとめてある。SG の具体的な設定手順は [VerifyGreen の セキュリティグループ設定](verify-green-security-group-setup.md) にある（**テンプレートは SG を作らない**）。

`VpcConfig` は **CodeBuild プロジェクトのプロパティ**なので、パイプライン実行ごとに切り替えられない。**設定するのは CloudFormation でスタックを作成／更新するときだけ**である。

```text
CollectMySqlRuntimeValues=true
VpcId=vpc-xxxxxxxx
VerifyGreenSubnetIds=subnet-aaaa,subnet-bbbb        # 検証専用。RDS へ到達でき、外部へは出ない
VerifyGreenSecurityGroupIds=sg-xxxxxxxx            # 下記「セキュリティグループ設定」で作る SG
VerifyGreenImage=<account>.dkr.ecr.<region>.amazonaws.com/rds-bg-verify-green:<tag>
```

`VpcId` が空なら `VerifyGreen` も VPC 外で動き、AWS API による検証だけを行う（既定）。

**VPC 内へ入れるのは `VerifyGreen` だけである。**

| プロジェクト | 配置 | 外部への経路 | 用途 |
|---|---|---|---|
| `BuildReportToolProject` | **VPC 外**（他の VPC 外プロジェクトと同じ） | ある（VPC の制約を受けない） | Go module を取得してビルドする |
| `VerifyGreenProject` | `VerifyGreenSubnetIds` | **不要** | RDS へ到達して検証する |

ビルドは AWS API も RDS も呼ばないので VPC へ入れる理由が無く、入れると NAT gateway と Elastic Network Interface 権限が要るだけになる。**検証専用 subnet には外部への経路を置かない。**

テンプレートは `VpcId` の指定を条件に、**両プロジェクトのロール**へ Elastic Network Interface（VPC 内のリソースに割り当てられる仮想ネットワークインターフェイス）の作成権限（`ec2:CreateNetworkInterface` など）を追加する。**この権限が無いと VPC 内の CodeBuild は起動に失敗する。**さらに絞るなら `ec2:CreateNetworkInterfacePermission` の `Condition` に `ec2:Subnet`（subnet の ARN）を加える。

#### 外部 egress を持たない場合に必要な VPC endpoint

`verify_green.sh` が呼ぶ API は次のとおりで、NAT を置かないなら endpoint が必要である。

| endpoint | 用途 | 種別 |
|---|---|---|
| `com.amazonaws.<region>.s3` | artifact の入出力 | Gateway |
| `com.amazonaws.<region>.logs` | ビルドログ | Interface |
| `com.amazonaws.<region>.rds` | `rds describe-db-instances` / `describe-blue-green-deployments` / `describe-db-parameters` | Interface |
| `com.amazonaws.<region>.monitoring` | `cloudwatch get-metric-statistics`（ReplicaLag） | Interface |
| `com.amazonaws.<region>.ssm` | 接続情報（SecureString）の取得 | Interface |

カスタマー管理キーで暗号化した SecureString を使う場合は `kms` も追加する。

#### MySQL クライアントは使わない

private subnet では apt リポジトリへ到達できないため、**buildspec は `apt-get` を呼ばない。**実効値の収集は `collect_green_runtime_values`（静的リンクの Go バイナリ）が行う。`BuildReportTool` がレポート生成器と一緒にビルドし、artifact で渡す。

**そのため `VerifyGreenImage` に既定以外を指定する必要は無い。**`aws/codebuild/standard:7.0` は jq・rbenv（Ruby 3.4.10）・AWS CLI v2 を持っており、足りなかったのは mysql クライアントだけだったためである。既定イメージ以外を指定した場合だけ、テンプレートは `ImagePullCredentialsType: SERVICE_ROLE` へ切り替え、`VerifyGreenRole` へ ECR 読み取り権限を条件付きで付与する。

> イメージが提供する managed runtime の Go バージョンは AWS の更新で変わる。`runtime-versions: golang: 1.25` が解決できない場合は、より新しい CodeBuild image を選ぶか、`go.mod` の `go` ディレクティブをイメージが提供するバージョンへ下げる。

### 任意の MySQL 実効値収集時だけ追加されるもの

`CollectMySqlRuntimeValues=true` の場合だけ、VerifyGreen は SSM Parameter Store から接続情報を取得し、Green DB へ 3306/tcp で接続する。**パッケージの導入は発生しない。**収集は事前ビルド済みの Go バイナリが行い、TLS の CA もそこへ焼き込んである。

したがって MySQL 接続をしない通常の Step 4 では、Green DB への接続そのものが発生しない。

## 1. 事前条件

次の情報・リソースを用意する。

| 項目 | 必要な情報または状態 | 用途 |
|---|---|---|
| ソースリポジトリ | **GitHub** なら `owner/repository`、**CodeCommit** ならリポジトリ名。いずれも対象ブランチ | CodePipeline が buildspec・スクリプト・環境設定を取得する |
| CodeConnections 接続 | GitHub 接続済み・`AVAILABLE` の Connection ARN | Source ステージが GitHub を読む。**CodeCommit を使う場合は不要** |
| S3 artifact bucket | 同一リージョンの既存バケット、暗号化・ライフサイクルを設定 | ソースと各 Step の成果物を保存する |
| CodePipeline 実行ロール | 既存 IAM role ARN | Pipeline が CodeConnections、S3、CodeBuild を利用する |
| CodeBuild 実行ロール | 既存 IAM role ARN | RDS・CloudWatch API と成果物を扱う |
| 環境設定 | `config/blue-green/<environment>.deployment.yml` の対象サービス定義 | Blue DB、8.4 PG、DB クラス、承認状態を決める |
| Step 2 完了 | MySQL 8.4 パラメータグループが CloudFormation で作成済み | Step 3 が `target_db_parameter_group_name` を RDS API へ渡す |

#### ソースの取得元を選ぶ

`SourceProvider` パラメータで切り替える。**後続ステージはどちらの場合も `SourceOutput` を受け取るため、Source ステージ以外は一切変わらない。**

| `SourceProvider` | 使うパラメータ | Source アクション |
|---|---|---|
| `CodeConnections`（既定） | `CodeStarConnectionArn`、`RepositoryId` | `SourceFromGitHub`（Provider: `CodeStarSourceConnection`） |
| `CodeCommit` | `CodeCommitRepositoryName` | `SourceFromCodeCommit`（Provider: `CodeCommit`） |

選ばなかった側のパラメータは無視される。**CodePipeline 実行ロールへ付く権限も、選んだ側だけになる**（all-in-one テンプレートはロールを作るので自動、`codepipeline.yml` は外部ロールなので下表の権限を自分で付ける）。

| `SourceProvider` | ロールに必要な権限 |
|---|---|
| `CodeConnections` | `codestar-connections:UseConnection` と `codeconnections:UseConnection`（接続はどちらの名前空間でも作られうるため両方）。対象は指定した接続 1 つ |
| `CodeCommit` | `codecommit:GetBranch` / `GetCommit` / `GetRepository` / `UploadArchive` / `GetUploadArchiveStatus` / `CancelUploadArchive`。対象はそのリポジトリ 1 つ |

**どちらも push では自動開始しない。**`CodeConnections` は `DetectChanges: 'false'`、`CodeCommit` は `PollForSourceChanges: 'false'`（EventBridge ルールも作らない）で、作業者が明示的に開始する設計である。

CodeConnections を使う場合は、接続作成後に GitHub 側で認可を完了させる必要がある。Connection ARN は CloudFormation パラメータ `CodeStarConnectionArn` に渡す。[CodeConnections の GitHub 接続手順](https://docs.aws.amazon.com/dtconsole/latest/userguide/connections-create-github.html)を参照する。

> **CodeCommit は新規利用が制限されている。**AWS は 2024-07-25 以降、CodeCommit を使ったことのないアカウントでの新規リポジトリ作成を受け付けていない。既に CodeCommit を使っているアカウントでは引き続き利用できる。新規に選ぶなら `CodeConnections` 側を推奨する。

artifact bucket は CodePipeline 実行リージョンに作成し、組織の要件に従い S3 バケット暗号化、パブリックアクセスブロック、保存期間を設定する。KMS カスタマー管理キーを使う場合は、後述の両 IAM ロールにそのキーの利用権限も必要となる。

## 2. IAM ロールと最小権限

テンプレートは IAM ロールを新規作成しない。既存ロール ARN を受け取るため、権限設計・信頼ポリシーは組織の IAM 管理に従って事前に作成する。

### CodePipeline 実行ロール

少なくとも次を許可する。

- artifact bucket に対する `s3:GetObject`、`s3:GetObjectVersion`、`s3:PutObject`、`s3:GetBucketVersioning`
- `codeconnections:UseConnection`（指定した Connection ARN のみ）
- 3 つの対象 CodeBuild project に対する `codebuild:StartBuild`、`codebuild:BatchGetBuilds`
- KMS のカスタマー管理キー を artifact bucket に使う場合の `kms:Decrypt`、`kms:Encrypt`、`kms:GenerateDataKey`

### CodeBuild 実行ロール

共通の読み取り権限として、対象リージョンの `rds:DescribeDBInstances`、`rds:DescribeBlueGreenDeployments`、`rds:DescribeDBParameterGroups`、`rds:DescribeDBParameters`、`rds:DescribeDBSnapshots`、`cloudwatch:GetMetricStatistics` を許可する。

Step ごとの変更権限は次のとおりである。

| Project | 追加権限 | 用途 |
|---|---|---|
| BuildGreen | `rds:CreateDBSnapshot`、`rds:CreateBlueGreenDeployment`、`rds:CreateDBInstanceReadReplica`、`rds:AddTagsToResource` | 保護スナップショットと Green の作成。Green のレプリカ作成とタグ付与は RDS が従属操作として行う |
| BuildGreen（条件付き） | **`iam:PassRole`** | **移行元が拡張モニタリングを使っている場合に必須。**下記を参照 |
| VerifyGreen | なし | AWS API と RDS パラメータの読み取りだけ |
| Switchover | `rds:SwitchoverBlueGreenDeployment`、`rds:ModifyDBInstance`、`rds:PromoteReadReplica` | 承認後の切替。RDS が Green DB を変更し、read replica を昇格するため三つとも必要 |

#### 拡張モニタリングを使っている場合の `iam:PassRole`

移行元 DB で拡張モニタリング（Enhanced Monitoring）が有効だと、**RDS は Green へその設定をコピーする。**このとき呼び出し側にモニタリングロールを渡す権限が要る。無いと Step 3 がこの形で失敗する。

```
User: arn:aws:sts::<account>:assumed-role/<build-green-role>/... is not authorized to
perform: iam:PassRole on resource: arn:aws:iam::<account>:role/rds-monitoring-role
```

移行元の設定はこれで確認できる。`MonitoringInterval` が `0` 以外なら有効である。

```bash
aws rds describe-db-instances --db-instance-identifier <blue-id> \
  --query 'DBInstances[0].[MonitoringInterval,MonitoringRoleArn]'
```

`codepipeline-all-in-one.yml` は **`RdsMonitoringRoleName` パラメータ**（既定 `rds-monitoring-role`）でこの権限を付ける。移行元が別名のロールを使っているならその名前に変え、拡張モニタリングを使っていないなら空文字にする（空なら権限自体が付かない）。

付与される内容は次のとおりで、**渡し先のサービスを Condition で固定**してある。他用途への流用を防ぐためである。

```yaml
- Sid: PassRdsMonitoringRole
  Effect: Allow
  Action: 'iam:PassRole'
  Resource: arn:aws:iam::<account>:role/<RdsMonitoringRoleName>
  Condition:
    StringEquals:
      'iam:PassedToService': monitoring.rds.amazonaws.com
```

外部ロールを渡す `codepipeline.yml` を使う場合は、同じ内容を `CodeBuildServiceRoleArn` のロールへ自分で付ける。

さらに CodeBuild の標準的な運用権限として、CloudWatch Logs のログ出力、artifact bucket の読み書き、KMS を使う場合の復号・暗号化を対象リソースに限定して許可する。RDS の変更 API は可能な範囲で対象 DB instance・snapshot・Blue/Green deployment の ARN に限定する。切替用ロールは `deployment:*`（切替）と `db:*`（RDS が行う DB instance の変更・昇格）に分ける。`Describe*` 系 API はリソースレベル制御ができない場合があるため、AWS IAM のサービス認可リファレンスで確認する。

## 3. Step 4 の実効値取得を有効にする場合だけ必要な設定

`CollectMySqlRuntimeValues` の既定値は `false` である。このままなら VerifyGreen は Green DB へ MySQL 接続せず、AWS API による検証だけを行う。

実効値もレポートへ載せる場合だけ、次を追加する。

1. SSM Parameter Store に SecureString パラメータを 2 本作成する。パスワード用（`parameter_name`）とユーザー名用（`user_parameter_name`）で、どちらも必須である。
2. `MySqlCredentialsParameterArns` にその 2 本の ARN をカンマ区切りで渡し、`CollectMySqlRuntimeValues=true` でスタックを更新する。
3. CodeBuild 実行ロールに、そのパラメータだけの `ssm:GetParameter` を許可する。カスタマー管理キーで暗号化した SecureString は `kms:Decrypt` も許可する。
4. `VerifyGreenProject` に、Green DB へ到達できる `VpcConfig`（VPC、private subnet、security group）を追加する。
5. MySQL ユーザーに `performance_schema.global_variables` を参照できる最小限の権限を与える。

VPC 内の CodeBuild から Go モジュール（`proxy.golang.org`）、S3、CloudWatch Logs、AWS API に到達できるよう、NAT gateway または必要な VPC endpoint を用意する。これは `CollectMySqlRuntimeValues=false` でも Go のビルドを行うため必要である。イメージの Go が `go.mod` の要求より古い場合は `GOTOOLCHAIN=auto` がツールチェーンを取得するため、その経路も同様に必要である。

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
    SourceProvider=CodeConnections \
    CodeStarConnectionArn=arn:aws:codeconnections:ap-northeast-1:123456789012:connection/xxxxxxxx \
    RepositoryId=your-org/your-repository \
    BranchName=main \
    ArtifactBucketName=your-codepipeline-artifact-bucket \
    CodePipelineServiceRoleArn=arn:aws:iam::123456789012:role/CodePipelineRdsBlueGreen \
    CodeBuildServiceRoleArn=arn:aws:iam::123456789012:role/CodeBuildRdsBlueGreen
```

初回は `CollectMySqlRuntimeValues` と `MySqlCredentialsParameterArns` を省略する。実効値取得を必要とするレビュー時だけ、ネットワーク・パラメータ・権限を確認したうえで以下を追加してスタック更新する。

```text
CollectMySqlRuntimeValues=true
MySqlCredentialsParameterArns=<パスワード用 ARN>,<ユーザー名用 ARN>
```

CodeCommit から取る場合は、`SourceProvider` と `CodeCommitRepositoryName` に差し替える（`CodeStarConnectionArn` と `RepositoryId` は渡さなくてよい）。

```text
SourceProvider=CodeCommit
CodeCommitRepositoryName=your-repository
BranchName=main
```

CloudFormation の `CodeStarConnectionArn`、artifact bucket、両実行ロールはスタック外で管理する。テンプレートを削除しても、これら既存リソースは削除されない。

## 5. 実行手順

### 5-1. 実行前の確認

1. Step 1 の成立条件チェックと Step 2 のパラメータグループ作成・レビューを完了する。
2. 対象サービスの `config/blue-green/<environment>.deployment.yml` を確認する。
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
- `PrivilegedMode` はどのプロジェクトにも設定しない。Go レポート生成器は Docker ではなく `runtime-versions: golang` でビルドし、Ruby は `rbenv local` で選ぶ。
- Step 4 の MySQL 実効値は YAML や `Source=user` と比較して合否を出す対象ではない。RDS の計算値・上限調整を含むため、人がレポートで判断する。

## 参考

- [AWS::CodePipeline::Pipeline CloudFormation リファレンス](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-codepipeline-pipeline.html)
- [AWS::CodeBuild::Project CloudFormation リファレンス](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-codebuild-project.html)
- [CodePipeline の CodeConnections source action](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodestarConnectionSource.html)
- [CodeBuild の buildspec リファレンス](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)
