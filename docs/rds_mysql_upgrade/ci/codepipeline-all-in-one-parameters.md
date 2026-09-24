# codepipeline-all-in-one のデプロイとパラメータ一覧

`examples/rds-blue-green-deployment/codepipeline-all-in-one.yml` を AWS CLI から登録する手順と、全パラメータのリファレンス。

**このテンプレートが作るもの**: S3 バケット（`ArtifactBucketName` 省略時のみ）とバケットポリシー、IAM ロール 7 本（CodeBuild 用 6 + CodePipeline 用 1）とマネージドポリシー 1 本、CodeBuild プロジェクト 6 本、CodePipeline 1 本。
**作らないもの**: RDS リソース、セキュリティグループ、VPC・subnet、SSM パラメータ、CodeConnections の接続、KMS キー。

構成の全体像は [パイプライン構成図](codepipeline-structure.md)、前提条件と設計上の判断は [セットアップ手順](codebuild-codepipeline-setup.md) にある。

## 1. 最小構成でのデプロイ

**必須は `EnvironmentName` だけ**で、他は既定値を持つ。ただし実用上は最低これだけ指定する。

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

`--capabilities CAPABILITY_NAMED_IAM` は必須である。IAM ロールを**名前付きで**作成するため、`CAPABILITY_IAM` では足りない。

**この構成でできること**: Step 3（Green 作成）→ Step 4（AWS API による検証）→ 承認 → Step 5（切替）→ 承認 → Step 7（後始末）。
**できないこと**: Green DB への MySQL 接続（実効値の収集）。有効化は「4. 実効値収集を有効にする」を参照する。

### デプロイ後の確認

```bash
aws cloudformation describe-stacks --stack-name rds-bg-staging \
  --query 'Stacks[0].Outputs' --output table
```

| 出力 | 内容 |
|---|---|
| `ArtifactBucket` | 使用しているアーティファクト用 S3 バケット名（自動作成した場合もここに出る） |
| `PipelineName` | 作成した CodePipeline 名 |
| `StartCommand` | サービスを指定して開始するコマンド（そのまま実行できる） |

### 実行

**push では自動開始しない。**作業者が明示的に開始する。

```bash
aws codepipeline start-pipeline-execution \
  --name rds-bg-staging \
  --variables name=ServiceName,value=example-service
```

## 2. CodeCommit をソースにする

```bash
aws cloudformation deploy \
  --template-file examples/rds-blue-green-deployment/codepipeline-all-in-one.yml \
  --stack-name rds-bg-staging \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName=staging \
    DefaultServiceName=example-service \
    SourceProvider=CodeCommit \
    CodeCommitRepositoryName=your-repository \
    "ProtectedRdsResourceArns=arn:aws:rds:ap-northeast-1:123456789012:db:example-service-staging*,arn:aws:rds:ap-northeast-1:123456789012:snapshot:example-service-staging*"
```

`CodeStarConnectionArn` と `RepositoryId` は渡さなくてよい（無視される）。CodePipeline ロールへ付く権限も CodeCommit 用に切り替わる。

## 3. 既存の S3 バケットを使う

既定では**バケットを自動作成する**。既存バケットを使う場合だけ名前を渡す。

```bash
    ArtifactBucketName=your-existing-codepipeline-artifact-bucket \
```

指定するとスタックは `AWS::S3::Bucket` も `AWS::S3::BucketPolicy` も作らない。**バージョニングを有効にしておくこと**（CodePipeline の要件）。

## 4. 実効値収集を有効にする

Green DB へ接続して `performance_schema.global_variables` を読み、レポートへ載せる。

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
    RdsMonitoringRoleName=rds-monitoring-role \
    CollectMySqlRuntimeValues=true \
    MySqlCredentialsParameterPath=/rds-bg/staging \
    VpcId=vpc-xxxxxxxx \
    VerifyGreenSubnetIds=subnet-aaaa,subnet-bbbb \
    VerifyGreenSecurityGroupIds=sg-xxxxxxxx
```

**カンマ区切りの値は引用符で囲む。**シェルに分割されると別のパラメータとして解釈される。

SecureString がカスタマー管理キーで暗号化されている場合だけ追加する（AWS 管理キー `alias/aws/ssm` なら不要）。

```bash
    MySqlCredentialsKmsKeyArn=arn:aws:kms:ap-northeast-1:123456789012:key/00000000-0000-0000-0000-000000000000 \
```

読むパラメータ名は **config が決める**。`MySqlCredentialsParameterPath` は IAM の許可範囲（その階層の配下）にすぎない。**環境の全サービスのパラメータをこの階層の下に置く**ので、サービスを増やしてもスタック更新は要らない。詳細は [セットアップ手順](codebuild-codepipeline-setup.md) にある。

## 5. パラメータファイルを使う

パラメータが増えると 1 行が長くなるため、ファイルに分けてもよい。

```bash
cat > .local/rds-bg-staging.json <<'JSON'
[
  { "ParameterKey": "EnvironmentName",             "ParameterValue": "staging" },
  { "ParameterKey": "DefaultServiceName",          "ParameterValue": "example-service" },
  { "ParameterKey": "CodeStarConnectionArn",       "ParameterValue": "arn:aws:codeconnections:ap-northeast-1:123456789012:connection/xxxxxxxx" },
  { "ParameterKey": "RepositoryId",                "ParameterValue": "your-org/your-repository" },
  { "ParameterKey": "ProtectedRdsResourceArns",    "ParameterValue": "arn:aws:rds:ap-northeast-1:123456789012:db:example-service-staging*,arn:aws:rds:ap-northeast-1:123456789012:snapshot:example-service-staging*" },
  { "ParameterKey": "RdsMonitoringRoleName",       "ParameterValue": "rds-monitoring-role" },
  { "ParameterKey": "CollectMySqlRuntimeValues",   "ParameterValue": "true" },
  { "ParameterKey": "MySqlCredentialsParameterPath", "ParameterValue": "/rds-bg/staging" },
  { "ParameterKey": "VpcId",                       "ParameterValue": "vpc-xxxxxxxx" },
  { "ParameterKey": "VerifyGreenSubnetIds",        "ParameterValue": "subnet-aaaa,subnet-bbbb" },
  { "ParameterKey": "VerifyGreenSecurityGroupIds", "ParameterValue": "sg-xxxxxxxx" }
]
JSON

aws cloudformation create-stack \
  --stack-name rds-bg-staging \
  --template-body file://examples/rds-blue-green-deployment/codepipeline-all-in-one.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://.local/rds-bg-staging.json
```

`create-stack` / `update-stack` は `--parameters`（`ParameterKey` / `ParameterValue` 形式）、`deploy` は `--parameter-overrides`（`KEY=VALUE` 形式）である。**両者で書式が違う。**`.local/` は `.gitignore` 済みだが、**認証情報そのものは書かない**（このファイルに入るのは ARN と識別子だけである）。

## 6. 更新と削除

### 更新

```bash
aws cloudformation deploy \
  --template-file examples/rds-blue-green-deployment/codepipeline-all-in-one.yml \
  --stack-name rds-bg-staging \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides <変更後の全パラメータ>
```

**`deploy` で省略したパラメータは既定値に戻る。**前回の値を引き継ぐわけではない。既存の値を保ちたい場合は、その名前を明示するか `--parameter-overrides` に `ParameterKey=...,UsePreviousValue=true` を使える `update-stack` を選ぶ。

現在の値はこれで確認できる。

```bash
aws cloudformation describe-stacks --stack-name rds-bg-staging \
  --query 'Stacks[0].Parameters' --output table
```

**削除したパラメータを渡すとエラーになる。**過去に存在した `VerifyGreenImage`、`BuildSubnetIds`、`BuildSecurityGroupIds` は現在のテンプレートには無い。

```
An error occurred (ValidationError): Parameters: [VerifyGreenImage] do not exist in the template
```

### 変更内容を事前に確認する

```bash
aws cloudformation deploy ... --no-execute-changeset
# 出力された change set 名で内容を確認してから
aws cloudformation execute-change-set --change-set-name <名前>
```

### 削除

```bash
aws cloudformation delete-stack --stack-name rds-bg-staging
```

**自動作成した S3 バケットは残る**（`DeletionPolicy: Retain`）。中身があるとバケットを削除できずスタック削除が失敗するためである。不要なら手で削除する。**IAM ロール・CodeBuild プロジェクト・CodePipeline は削除される。**RDS リソースには一切影響しない。

## 7. パラメータ一覧

`(必須)` 以外は既定値のままでも `deploy` が通る。

### パイプライン

| パラメータ | 型 | 既定値 | 内容 |
|---|---|---|---|
| `EnvironmentName` | String | **(必須)** | `staging` / `production`。`config/blue-green/<この値>.deployment.yml` を読む。リソース名にも入る |
| `PipelineNamePrefix` | String | `rds-bg` | CodePipeline・CodeBuild・IAM ロール名の共通接頭辞 |
| `DefaultServiceName` | String | `example-service` | 対象サービスの既定値。実行時に `--variables name=ServiceName,value=...` で上書きできる |
| `ArtifactBucketName` | String | `''` | **空ならバケットを新規作成する。**名前は `<Prefix>-<Env>-artifacts-<AccountId>-<Region>`。既存名を渡すとスタックはバケットに触らない |
| `ArtifactRetentionDays` | Number | `90` | 新規作成したバケットでアーティファクトを保持する日数（1〜3650）。既存バケット指定時は使わない |

### ソース

| パラメータ | 型 | 既定値 | 内容 |
|---|---|---|---|
| `SourceProvider` | String | `CodeConnections` | `CodeConnections`（GitHub）/ `CodeCommit`。Source アクションと CodePipeline ロールの権限が入れ替わる |
| `CodeStarConnectionArn` | String | `arn:aws:codeconnections:ap-northeast-1:123456789012:connection/0000...` | `CodeConnections` のときの接続 ARN。**既定値は仮置きなので必ず置き換える。**事前に `AVAILABLE` にしておく |
| `RepositoryId` | String | `your-org/your-repository` | `CodeConnections` のときの `owner/repo` |
| `CodeCommitRepositoryName` | String | `''` | `CodeCommit` のときのリポジトリ名。**この場合は必須** |
| `BranchName` | String | `main` | 取得するブランチ。両プロバイダ共通 |

`CodeStarConnectionArn` と `RepositoryId` の既定値は**仮置き**である。`CodeConnections` を使うなら必ず実際の値へ置き換える。

### Step 4 の MySQL 実効値収集（任意）

| パラメータ | 型 | 既定値 | 内容 |
|---|---|---|---|
| `CollectMySqlRuntimeValues` | String | `false` | `true` で Green DB へ接続し実効値を収集する。`false` なら AWS API の検証だけ |
| `MySqlCredentialsParameterPath` | String | `''` | `ssm:GetParameter` を許す SSM パラメータの**階層**（例 `/rds-bg/staging`）。その配下すべてが読める。**IAM の許可範囲であり、読む名前は config が決める。**先頭 `/` 必須・末尾 `/` なし（`AllowedPattern` で検査） |
| `MySqlCredentialsKmsKeyArn` | String | `''` | SecureString を暗号化している CMK の ARN。**AWS 管理キーなら空のまま。**指定すると `kms:ViaService` で SSM 経由に限定した `kms:Decrypt` が付く |

### Step 4 検証の VPC 配置（任意）

| パラメータ | 型 | 既定値 | 内容 |
|---|---|---|---|
| `VpcId` | String | `''` | **`VerifyGreen` だけ**を置く VPC。空なら VPC 外で動き Green DB へ接続できない。`BuildReportTool` は常に VPC 外 |
| `VerifyGreenSubnetIds` | CommaDelimitedList | `''` | 検証専用の private subnet。RDS へ到達できること。**外部への経路は要らない**（2 アベイラビリティゾーン以上を推奨） |
| `VerifyGreenSecurityGroupIds` | CommaDelimitedList | `''` | `VerifyGreen` に付ける SG。**テンプレートは SG を作らない**ので別途用意する（[設定手順](verify-green-security-group-setup.md)） |

`VpcId` を指定すると `VerifyGreenRole` へ Elastic Network Interface の作成権限が自動で付く。

### 保護対象の RDS リソース

`ProtectedRdsResourceArns` は `BuildGreenRole`（`rds:CreateDBSnapshot` 等）の `Resource` にそのまま入る。IAM の `Resource` はリストを取れるため、**移行対象が複数あればそのまま列挙できる。**

**`db` と `snapshot` の 2 種類が必要である。**保護スナップショットの作成は、元の DB インスタンス（`db`）に対する操作と、作られるスナップショット（`snapshot`）に対する操作の両方で認可されるためで、片方だけでは失敗する。

| 指定 | 有効範囲 | 評価 |
|---|---|---|
| `arn:aws:rds:ap-northeast-1:123456789012:db:example-service-staging*,arn:aws:rds:ap-northeast-1:123456789012:snapshot:example-service-staging*` | その識別子で始まる DB とスナップショット | **推奨** |
| 空（既定） | このアカウント・リージョンの `db:*` と `snapshot:*` | 種類・アカウント・リージョンでは絞られるが識別子では絞られない。検証用 |
| `*` | 全リソース | **動作はするが推奨しない。**RDS 以外にも及ぶ |

複数サービス分を生成するならシェルで組み立てるとよい。

```bash
region=ap-northeast-1; account=123456789012
arns=$(for prefix in example-service-staging another-service-staging; do
  for type in db snapshot; do
    printf 'arn:aws:rds:%s:%s:%s:%s*,' "$region" "$account" "$type" "$prefix"
  done
done | sed 's/,$//')
echo "$arns"
```

### その他

| パラメータ | 型 | 既定値 | 内容 |
|---|---|---|---|
| `RdsMonitoringRoleName` | String | `rds-monitoring-role` | 移行元が拡張モニタリングで使っている IAM ロール名。**`iam:PassRole` の対象になる。**使っていなければ空にする。名前が違うと Step 3 が `AccessDenied` で失敗する |
| `ProtectedRdsResourceArns` | CommaDelimitedList | `''` | RDS の変更権限（保護スナップショットの作成）の対象 ARN。**複数指定できる。**`db` と `snapshot` の**両方**を入れる。詳細は下記 |
| `ApprovalNotificationTopicArn` | String | `''` | 手動承認の通知先 SNS トピック。空なら通知しない |

## 8. 指定を誤りやすい箇所

| パラメータ | よくある誤り | 結果 |
|---|---|---|
| `ProtectedRdsResourceArns` | `snapshot:` の ARN を入れ忘れる | 保護スナップショットの作成が `AccessDenied` で失敗する |
| `ProtectedRdsResourceArns` | 空のまま本番へ適用する | アカウント・リージョン内の全 DB インスタンスとスナップショットが対象になる。**必ず絞る** |
| `ProtectedRdsResourceArns` | 引用符で囲まない | カンマでシェルに分割され、別パラメータとして解釈される |
| `RdsMonitoringRoleName` | 移行元の実際のロール名と違う | Step 3 が `iam:PassRole` の `AccessDenied` で失敗する |
| `MySqlCredentialsParameterPath` | サービスのパラメータを階層の外に置く | そのサービスの実行時に `ssm:GetParameter` が `AccessDenied` になる |
| `MySqlCredentialsParameterPath` | 移行用以外の秘密を同じ階層に置く | VerifyGreen がそれも読めてしまう。**階層は移行作業専用にする** |
| `VerifyGreenSubnetIds` | パブリック subnet を指定する | 動くが、検証を隔離する設計の意図が崩れる |
| `ArtifactBucketName` | 既存スタックで空に変える | `ArtifactStore.Location` が変わり、それまでのアーティファクトを参照できなくなる |
| `EnvironmentName` | config に無い環境名を渡す | 実行時に設定ファイルが読めず失敗する（`AllowedValues` で `staging` / `production` に制限している） |
