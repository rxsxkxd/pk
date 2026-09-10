# AWS CodeBuild 実環境の外部接続先と認証

この文書は、AWS 上で動く `BuildGreenProject`、`VerifyGreenProject`、`SwitchoverProject` の CodeBuild 実行だけを対象にする。CodeBuild Local Agent、開発者端末での `scripts/*.sh` 直接実行、GitHub Actions は対象外である。

CodePipeline の Source ステージが GitHub からソースを取得する通信も対象外とする。CodeBuild は CodePipeline から渡された source artifact と、`ci/codebuild/` 配下の buildspec を実行する。

## 1. 接続パターンの全体像

```text
CodeBuild 実行コンテナ
  ├─ AWS API（CodeBuild サービスロールの一時認証情報）
  │    ├─ Amazon RDS control plane
  │    ├─ Amazon CloudWatch
  │    └─ AWS Secrets Manager                 # 実効値収集を有効にした場合だけ
  ├─ RDS for MySQL data plane（DB ユーザー認証） # 実効値収集を有効にした場合だけ
  └─ 公開パッケージ／コンテナ配布元
       ├─ PyPI                                # PyYAML が image にない場合だけ
       ├─ Docker Hub と Go module 配布元       # VerifyGreen では常時
       └─ Ubuntu apt repository                # MySQL client が image にない場合だけ

CodeBuild サービス連携
  ├─ S3 / KMS（CodePipeline source・artifact）
  └─ CloudWatch Logs（build log）
```

`VerifyGreenProject` の `CollectMySqlRuntimeValues` は既定で `false` である。既定運用では Secrets Manager と RDS MySQL data plane への接続は発生しない。

## 2. 実行コンテナからの接続

| 接続先 | 呼び出し元・用途 | 実行される条件 | 認証の解決 |
|---|---|---|---|
| Amazon RDS control plane | AWS CLI で DB インスタンス、Blue/Green deployment、DB パラメータグループ、スナップショットを参照し、Step 3／5 では snapshot 作成、Blue/Green 作成、切替も行う | Step 3〜5 で常時。変更 API は `actions` の承認状態により実行を抑止 | CodeBuild サービスロールの一時 AWS 認証情報。AWS CLI の標準 credential provider chain が自動取得する |
| Amazon CloudWatch | `AWS/RDS` の `ReplicaLag` を VerifyGreen で読む | VerifyGreen で常時 | CodeBuild サービスロールの一時 AWS 認証情報 |
| AWS Secrets Manager | MySQL の `username`／`password` を `GetSecretValue` で読む | `CollectMySqlRuntimeValues=true` の場合だけ | CodeBuild サービスロールの一時 AWS 認証情報。secret が CMK 暗号化なら KMS の復号権限も必要 |
| RDS for MySQL data plane | `mysql` クライアントで `performance_schema.global_variables` を読む | `CollectMySqlRuntimeValues=true` の場合だけ | Secrets Manager から取得した DB ユーザー名／パスワード。AWS IAM 認証ではない |
| PyPI | `PyYAML==6.0.2` を導入する | managed image に `yaml` モジュールがない場合だけ | 既定は公開 PyPI への TLS 接続で、アプリケーション認証なし。組織の private index／proxy を設定した場合はその認証方式に従う |
| Docker Hub、Go module 配布元 | `golang:1.25` を取得し、`gopkg.in/yaml.v3` をダウンロードして Go レポート生成器をビルドする | VerifyGreen で常時 | 既定は公開イメージ・公開 module のためアプリケーション認証なし。Docker Hub のレート制限・組織プロキシを使う場合は別途 Docker registry 認証を設定 |
| Ubuntu apt repository | `mysql` コマンドが存在しない時に `mysql-client` を導入する | `CollectMySqlRuntimeValues=true` かつ image に MySQL client がない場合だけ | 公開 repository への TLS 接続で、アプリケーション認証なし。組織ミラー／proxy 使用時はその認証方式に従う |

### 2-1. RDS control plane の API 範囲

RDS への AWS CLI 接続は「パラメータグループ」と「Blue/Green」だけではない。実際には以下も取得する。

| buildspec / Step | 主な API |
|---|---|
| BuildGreen（Step 3） | `DescribeDBInstances`、`DescribeBlueGreenDeployments`、`DescribeDBSnapshots`、`CreateDBSnapshot`、`CreateBlueGreenDeployment` |
| VerifyGreen（Step 4） | `DescribeDBInstances`、`DescribeBlueGreenDeployments`、`DescribeDBParameters` |
| Switchover（Step 5） | `DescribeDBInstances`、`DescribeBlueGreenDeployments`、`SwitchoverBlueGreenDeployment` |

RDS API の認可は DB 接続ユーザーではなく、すべて CodeBuild サービスロールの IAM ポリシーで行う。

### 2-2. MySQL 接続の認証と TLS

MySQL 接続は、Secrets Manager secret の JSON にある `username` と `password` を、`MYSQL_USER`／`MYSQL_PASSWORD` として当該シェルプロセスにだけ渡して行う。パスワードは CodeBuild の通常環境変数、コマンド引数、artifact へ保存しない。

現行の `ci/codebuild/verify-green.yml` は `--ssl-ca` や `--ssl-mode=VERIFY_CA` を `collect_green_runtime_values.sh` に渡していない。そのため、CA を用いたサーバー証明書検証はスクリプトの現行経路では強制されない。RDS MySQL 接続に証明書検証を必須とする場合は、RDS CA bundle を安全に CodeBuild へ供給し、`--ssl-ca` を渡す実装とする必要がある。

また、DB は通常 VPC 内にあるため、`CollectMySqlRuntimeValues=true` の場合は `VerifyGreenProject` に Green DB へ到達可能な subnet と security group の `VpcConfig` が必要である。DB の security group は CodeBuild の security group から MySQL ポートへの到達だけを許可する。

## 3. AWS API 認証の解決手順

AWS CLI を使う buildspec やシェルスクリプトは、`aws configure`、named profile、アクセスキーの静的環境変数を設定しない。認証は次の順で解決される。

1. `CodeBuildServiceRoleArn` に指定する IAM role の信頼ポリシーで、`codebuild.amazonaws.com` に `sts:AssumeRole` を許可する。
2. 各 CodeBuild project に設定済みの `ServiceRole` が、この IAM role を参照する。
3. CodeBuild サービスが実行開始時に当該ロールを引き受け、短期の AWS 認証情報を実行コンテナへ提供する。
4. 実行コンテナ内の AWS CLI は標準 credential provider chain により、その一時認証情報を使って RDS、CloudWatch、必要時の SSM Parameter Store を SigV4 署名付きで呼び出す。
5. IAM ポリシーは API ごとに認可を判断する。SecureString を CMK で暗号化している場合は、Parameter Store の認可に加えて KMS の `Decrypt` も必要になる。

このため、CodeBuild 実環境用の `CONFIG_FILE` と `SERVICE_NAME` は認証情報ではない。いずれも通常の環境変数であり、AWS API を呼べるかどうかは CodeBuild サービスロールで決まる。接続情報そのものは config の `mysql_verification` が指す SSM パラメータ側にあり、CodeBuild の環境変数には現れない。

最低限の IAM 権限の詳細は [CodeBuild / CodePipeline セットアップ手順](codebuild-codepipeline-setup.md#2-iam-ロールと最小権限) を参照する。

## 4. CodeBuild サービス連携による接続

以下は buildspec のコマンドが直接呼び出す API ではないが、AWS 上の CodeBuild 実行に伴って必要となるサービス連携である。

| 接続先 | 用途 | 認証主体 |
|---|---|---|
| Amazon S3 | CodePipeline が渡す source artifact の取得、各 build の artifact の受け渡し | CodePipeline 実行ロールと CodeBuild サービスロール。CMK 使用時は KMS 権限も必要 |
| AWS KMS | S3 artifact または Secrets Manager secret がカスタマー管理キーで暗号化されている場合の復号・暗号化 | 利用するロールに対象キーの `kms:Decrypt`、用途により `kms:Encrypt`／`kms:GenerateDataKey` |
| Amazon CloudWatch Logs | CodeBuild の標準 build log 出力 | CodeBuild サービスロールに Logs 出力権限。CodeBuild サービスがログ配送を管理 |

CodeConnections による GitHub 接続は CodePipeline の Source ステージの責務であり、CodeBuild 実行コンテナから GitHub API を直接呼び出すものではない。

## 5. ネットワーク設計時の確認事項

- RDS、CloudWatch、Secrets Manager、S3、KMS、CloudWatch Logs は、CodeBuild の実行リージョンに対応する AWS service endpoint へ到達できることを確認する。
- `VerifyGreenProject` は Docker Hub と Go module 配布元へ到達する必要がある。PyYAML または MySQL client の動的導入が発生する環境では、PyPI と apt repository も必要になる。
- CodeBuild を VPC 内に置く場合、RDS MySQL への private 接続に加え、上記の AWS service endpoint と公開配布元への egress を NAT gateway、HTTPS proxy、VPC endpoint、組織ミラーの方針に沿って設計する。
- Docker Hub／PyPI／apt／Go module への通信を許可しない方針なら、依存物を含むカスタム CodeBuild image と、組織内 registry・package mirror を用意して buildspec の取得元を置き換える。

## 6. 対象外

- CodeBuild Local Agent がホストの Docker daemon、ローカル AWS profile、ローカルファイルへ接続する経路
- GitHub Actions の checkout、OIDC、artifact upload
- CodePipeline Source ステージの CodeConnections 経由 GitHub 接続
- CodeBuild managed image を CodeBuild サービスがプロビジョニング時に取得する内部経路

## 7. AWS 上の CodeBuild／CodePipeline 構成を用意する概要

ここまでの接続・認証は、CodeBuild project と CodePipeline がすでに作成済みであることを前提にしている。これらを AWS 上に構築・更新する段階では CloudFormation を使うが、構築後の CodeBuild 実行中に CloudFormation API は呼び出さない。

構築の流れは次のとおりである。

1. CodePipeline artifact 用の S3 bucket、CodePipeline 実行ロール、CodeBuild サービスロールを組織の方針に従って用意する。CMK を使う場合は、両ロールに対象キーの利用権限を付与する。
2. GitHub repository と CodeConnections 接続を作成し、GitHub 側の認可を完了して接続を `AVAILABLE` にする。
3. Step 2 で、対象サービスの MySQL 8.4 DB パラメータグループを CloudFormation で作成し、`config/blue-green/<environment>.deployment.yml` の `target_db_parameter_group_name` と一致させる。
4. [codepipeline.yml](../examples/rds-blue-green-deployment/codepipeline.yml) を CloudFormation で deploy する。このテンプレートは BuildGreen、VerifyGreen、Switchover の三つの CodeBuild project と、それらを順に呼び出す CodePipeline を作成する。
5. テンプレートの `CodeBuildServiceRoleArn` に Step 3〜5 用のサービスロールを渡す。trust policy は `codebuild.amazonaws.com` に `sts:AssumeRole` を許可し、RDS／CloudWatch と必要時の Secrets Manager、artifact／log 出力に必要な最小権限を設定する。
6. MySQL 実効値を収集する場合だけ、secret ID、CodeBuild の VPC 設定、RDS security group を追加する。既定の `CollectMySqlRuntimeValues=false` ではこの DB 接続設定は不要である。
7. `actions.build` と `actions.switchover` の承認状態、対象サービス・環境の設定をレビューしたうえで、CodePipeline を明示的に開始する。

CloudFormation のパラメータ、IAM 権限、VPC 設定、デプロイコマンドを含む詳細手順は [CodeBuild / CodePipeline セットアップ手順](codebuild-codepipeline-setup.md) を参照する。
