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
  └─ build:    CGO_ENABLED=0 go build ... -o .tools/green-report/... ./scripts/<コマンド名>
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
```

**イメージの指定は要らない。**`VerifyGreen` は `aws/codebuild/standard:7.0` 固定で、テンプレートはカスタムイメージを受け付けない。

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

> **SecureString の復号のために `kms` endpoint を足す必要はない。**カスタマー管理キーを使う場合でも、`ssm get-parameter --with-decryption` の復号は **SSM の側で行われる**ため、ビルドコンテナが KMS を直接呼ぶことはない。必要になるのは IAM 権限（`kms:Decrypt`）だけで、通信経路は `ssm` endpoint のみである。

#### MySQL クライアントは使わない

private subnet では apt リポジトリへ到達できないため、**buildspec は `apt-get` を呼ばない。**実効値の収集は `collect_green_runtime_values`（静的リンクの Go バイナリ）が行う。`BuildReportTool` がレポート生成器と一緒にビルドし、artifact で渡す。

**そのため `VerifyGreen` のイメージは `aws/codebuild/standard:7.0` 固定である。**同イメージは jq・rbenv（Ruby 3.4.10）・AWS CLI v2 を持っており、足りなかったのは mysql クライアントだけだったためである。**テンプレートからはカスタムイメージの指定（`VerifyGreenImage` パラメータ、`ImagePullCredentialsType`、ECR 読み取り権限）を削除した。**

> 以前の方式（MySQL クライアント入りのイメージを ECR へ置く）で使っていた [Dockerfile.verify-green](Dockerfile.verify-green) は、**参考として残してあるが未使用である。**テンプレートから指定する経路は無い。

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
| S3 artifact bucket | **`codepipeline-all-in-one.yml` は省略可**（空なら新規作成する）。`codepipeline.yml` は同一リージョンの既存バケットが必須 | ソースと各 Step の成果物を保存する |
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

#### artifact bucket を作らせる場合

`codepipeline-all-in-one.yml` は **`ArtifactBucketName` を空にすると自分で作る**。名前は次の形で、グローバルな一意性を満たすようアカウント ID とリージョンを含める。

```
<PipelineNamePrefix>-<EnvironmentName>-artifacts-<AccountId>-<Region>
```

作られるバケットの設定は次のとおりである。

| 設定 | 値 | 理由 |
|---|---|---|
| バージョニング | `Enabled` | **CodePipeline のアーティファクトバケットは必須** |
| 暗号化 | SSE-S3（`AES256`、バケットキー有効） | 既定で追加費用が無い |
| パブリックアクセス | 4 項目すべてブロック | — |
| Object Ownership | `BucketOwnerEnforced` | ACL を無効化し、IAM とバケットポリシーだけで制御する |
| ライフサイクル | 現行版は `ArtifactRetentionDays`（既定 90 日）で失効、非現行版 7 日、不完全マルチパートを 7 日で中止 | バージョニングが有効なので、明示的に失効させないと版が積み続ける |
| バケットポリシー | 非 TLS（`aws:SecureTransport: false`）を `Deny` | — |

**`DeletionPolicy: Retain` にしてある。**S3 は中身が残っているとバケットを削除できず、スタック削除が `DELETE_FAILED` で止まる。アーティファクトには移行作業の記録（検証レポート、収集した JSON）が入るため、スタックを消しても残す方を選んだ。不要になったら手で削除する。ライフサイクルで保持日数を過ぎれば空になるので、放置してもコストは増え続けない。

使ったバケット名はスタックの出力 `ArtifactBucket` で確認できる。

```bash
aws cloudformation describe-stacks --stack-name <名前> \
  --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucket`].OutputValue' --output text
```

#### 既存バケットを使う場合

`ArtifactBucketName` に名前を渡す。この場合スタックは `AWS::S3::Bucket` も `AWS::S3::BucketPolicy` も作らず、既存バケットの暗号化・パブリックアクセスブロック・ライフサイクル・バケットポリシーを変更しない。CodePipeline 実行リージョンに作成し、組織の要件に従って設定する。**バージョニングは有効にしておく**（CodePipeline の要件である）。KMS カスタマー管理キーを使う場合は、両 IAM ロールにそのキーの利用権限も必要となる。

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

### 接続情報の取得元 — 2 層に分かれている

**「どのパラメータを読むか」は設定 YAML が決める。CloudFormation のパラメータは IAM の許可リストにすぎない。**この 2 つを混同しやすいので先に整理する。

| | 決めるもの | 場所 | 粒度 |
|---|---|---|---|
| 設定 YAML | **読むパラメータ名** | `config/blue-green/<env>.deployment.yml` の `services.<name>.mysql_verification` | **サービス（= 移行対象 DB）ごと** |
| CloudFormation | `ssm:GetParameter` を許す**階層** | `MySqlCredentialsParameterPath` | スタック（= 環境）単位 |

実際の取得は `scripts/lib/mysql_credentials.sh` が行う。config から解決した名前をそのまま使い、**CloudFormation から名前を受け取ることはしない。**

```bash
aws ssm get-parameter --name "<parameter_name>"      --with-decryption   # パスワード
aws ssm get-parameter --name "<user_parameter_name>" --with-decryption   # ユーザー名
```

### ターゲット DB ごとに変えられる

パラメータ名は `services.<name>` 配下なので、DB ごとに別のパラメータを指せる。一方 **パイプラインは環境ごとに 1 本**で、サービスは実行時のパイプライン変数 `ServiceName` で切り替える。`VerifyGreenRole` も全サービスで共有する。

したがって **その環境の全サービスのパラメータを 1 つの階層の下に置き、その階層を `MySqlCredentialsParameterPath` に渡す。**

設定例。`staging` に 2 サービスある場合を示す。

```yaml
# config/blue-green/staging.deployment.yml
services:
  example-service:
    mysql_verification:
      enabled: true
      auth_method: parameter_store
      parameter_name: /rds-bg/staging/example-service/mysql/password
      user_parameter_name: /rds-bg/staging/example-service/mysql/user
      port: 3306
  another-service:
    mysql_verification:
      enabled: true
      auth_method: parameter_store
      parameter_name: /rds-bg/staging/another-service/mysql/password
      user_parameter_name: /rds-bg/staging/another-service/mysql/user
      port: 3306
```

これに対して渡す CloudFormation パラメータは **階層 1 つ**である。

```text
CollectMySqlRuntimeValues=true
MySqlCredentialsParameterPath=/rds-bg/staging
```

テンプレートはこれを次の IAM `Resource` に組み立てる。

```
arn:aws:ssm:<region>:<account>:parameter/rds-bg/staging/*
```

| 利点 | 内容 |
|---|---|
| **サービスを増やしてもスタック更新が要らない** | 新しいサービスのパラメータを同じ階層に置けば読める |
| リージョンとアカウント ID を書かなくてよい | テンプレートが `${AWS::Region}` / `${AWS::AccountId}` で補う |
| 環境をまたがない | `/rds-bg/staging/*` は `/rds-bg/production/...` にも `/rds-bg/staging-other/...` にも一致しない |

**トレードオフは許可範囲である。**列挙した N 本だけでなく、**その階層の配下すべてが読める。**そのため **この階層には移行作業用のパラメータだけを置く**（他用途の秘密を同じ階層に置かない）。

**指定の形に注意する。**`AllowedPattern` で次の形だけを受け付ける。

| 値 | 可否 |
|---|---|
| `/rds-bg/staging` | 受理 |
| `rds-bg/staging`（先頭 `/` なし） | **拒否** |
| `/rds-bg/staging/`（末尾 `/` あり） | **拒否** |
| `arn:aws:ssm:...`（ARN を渡した） | **拒否** |

先頭の `/` はパラメータ名の一部であり、ARN では `parameter` の直後にそのまま続く（`parameter` と名前の間に `/` を重ねない）。末尾 `/` を禁じているのは、テンプレートが `/*` を足すためである。

```
名前: /rds-bg/staging/example-service/mysql/password
ARN : arn:aws:ssm:<region>:<account>:parameter/rds-bg/staging/example-service/mysql/password
```

```bash
aws cloudformation deploy \
  --template-file examples/rds-blue-green-deployment/codepipeline-all-in-one.yml \
  --stack-name rds-bg-staging \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    CollectMySqlRuntimeValues=true \
    MySqlCredentialsParameterPath=/rds-bg/staging \
    VpcId=vpc-xxxxxxxx \
    VerifyGreenSubnetIds=subnet-aaaa,subnet-bbbb \
    VerifyGreenSecurityGroupIds=sg-xxxxxxxx
```

DB ごとに権限を完全に分離したいなら、`EnvironmentName` を分けてスタックを別に作る。

### 手順

1. SSM Parameter Store に SecureString パラメータを、**サービスごとに 2 本、環境ごとの階層の下に**作成する。パスワード用（`parameter_name`）とユーザー名用（`user_parameter_name`）で、`auth_method: parameter_store` ではどちらも必須である
2. config の該当サービスへ `enabled: true`、`auth_method: parameter_store`、2 つのパラメータ名を書く
3. `MySqlCredentialsParameterPath` に**その階層**（例 `/rds-bg/staging`）を渡し、`CollectMySqlRuntimeValues=true` でスタックを更新する
4. `VpcId` / `VerifyGreenSubnetIds` / `VerifyGreenSecurityGroupIds` を指定し、VerifyGreen を Green DB へ到達できる subnet へ置く（[セキュリティグループ設定](verify-green-security-group-setup.md)）
5. MySQL ユーザーに `performance_schema.global_variables` を参照できる最小限の権限を与える

#### 暗号化キーが CMK の場合

**AWS 管理キー（`alias/aws/ssm`）なら何もしなくてよい。**この場合 SSM が代理で復号するため、呼び出し側に `kms:Decrypt` は要らない。

カスタマー管理キー（CMK）で暗号化している場合は `MySqlCredentialsKmsKeyArn` にそのキーの ARN を渡す。

```text
MySqlCredentialsKmsKeyArn=arn:aws:kms:ap-northeast-1:123456789012:key/00000000-0000-0000-0000-000000000000
```

どちらのキーかは次で確認できる。`alias/aws/ssm` なら AWS 管理キー、キー ID や ARN が返れば CMK である。

```bash
aws ssm describe-parameters \
  --parameter-filters "Key=Name,Values=/rds-bg/staging/example-service/mysql/password" \
  --query 'Parameters[0].KeyId'
```

指定すると `VerifyGreenRole` へ次のステートメントが付く。

```yaml
- Sid: DecryptMySqlCredentials
  Effect: Allow
  Action: 'kms:Decrypt'
  Resource: <指定した CMK の ARN>     # このキー 1 つに限る
  Condition:
    StringEquals:
      'kms:ViaService': ssm.<region>.amazonaws.com
```

**`kms:ViaService` が要点である。**これが無いと、このロールはそのキーで暗号化された**あらゆる暗号文**を自力で復号できてしまう。付けることで、できるのは Parameter Store のパラメータを読むことだけになる。

**KMS は IAM ポリシーとキーポリシーの両方で許可されて初めて通る。**キーはこのスタックの外にあるため、キーポリシー側はテンプレートでは設定できない。

| キーポリシーの形 | 追加作業 |
|---|---|
| アカウントのルートへ委任する標準の形（`Principal: {"AWS": "arn:aws:iam::<account>:root"}` に `kms:*` を許可） | **不要。**上の指定だけで足りる |
| principal を絞っている | **`VerifyGreenRole` の ARN をキーポリシーへ手で追記する** |

ロール ARN はスタックの出力からは取れないので、名前から組む（`<PipelineNamePrefix>-<EnvironmentName>-verify-green`）。

**VerifyGreen 側に外部ネットワークは要らない。**Go のビルドは `BuildReportTool`（VPC 外）が担い、MySQL クライアントも使わないため、この subnet に NAT gateway を置く必要はない。VPC 内から呼ぶ AWS API 用の VPC endpoint は [Step 4 の分離と VPC 配置](verify-green-vpc-architecture.md) にまとめてある。

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

初回は `CollectMySqlRuntimeValues` と `MySqlCredentialsParameterPath` を省略する。実効値取得を必要とするレビュー時だけ、ネットワーク・パラメータ・権限を確認したうえで以下を追加してスタック更新する。

```text
CollectMySqlRuntimeValues=true
MySqlCredentialsParameterPath=/rds-bg/staging
```

CodeCommit から取る場合は、`SourceProvider` と `CodeCommitRepositoryName` に差し替える（`CodeStarConnectionArn` と `RepositoryId` は渡さなくてよい）。

```text
SourceProvider=CodeCommit
CodeCommitRepositoryName=your-repository
BranchName=main
```

`codepipeline.yml` では `CodeStarConnectionArn`、artifact bucket、両実行ロールをスタック外で管理する。テンプレートを削除しても、これら既存リソースは削除されない。`codepipeline-all-in-one.yml` が作ったバケットも `DeletionPolicy: Retain` のため削除されない。

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
