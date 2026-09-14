# CodeBuild / CodePipeline 実行定義

CloudFormation で CodePipeline と CodeBuild プロジェクトを作成する。テンプレートは 2 種類あり、S3 バケットと IAM ロールを自分で作るかどうかで使い分ける（後述の「2 つのテンプレート」）。

デプロイ前に構成を確認する場合は [パイプライン構成図](codepipeline-structure.md) を参照する。ステージ・IAM 権限・実行シナリオをテンプレートの定義から起こしてある。

AWS 側に用意するリソース、IAM、ネットワーク、Secrets、デプロイ・実行手順は [CodeBuild / CodePipeline セットアップ手順](codebuild-codepipeline-setup.md) を参照する。

AWS 上の CodeBuild 実行時に限った外部接続先、接続条件、認証の解決方法は [CodeBuild 実環境の外部接続先と認証](codebuild-remote-external-access.md) を参照する。

各 CodeBuild buildspec を CodePipeline なしでローカル確認する手順は [CodeBuild 各フローの単体ローカル検証](codebuild-local-verification.md) を参照する。

```text
codepipeline.yml:
  CodeConnections (GitHub) → BuildGreen → VerifyGreen → ManualApproval → Switchover
                               Step 3       Step 4          人の承認        Step 5

codepipeline-all-in-one.yml:
  CodeConnections (GitHub) → ReadApprovals → PrecheckPG → BuildGreen → VerifyGreen
                             config を読む    Step 2 確認    Step 3       Step 4
    → [Switchover]  承認 → 切替          ※ actions.switchover が approved のときだけ入る
    → [Cleanup]     承認 → 削除          ※ actions.cleanup が approved のときだけ入る
```

`[ ]` で囲んだステージには**入場条件**が付いている。`ReadApprovals` が config の `actions` をパイプライン変数として公開し、`BeforeEntry` の `VariableCheck` が `approved` でなければ**ステージごとスキップ**する。

このため 1 本のパイプラインを各フェーズで繰り返し実行できる。

| config の状態 | パイプラインの挙動 |
|---|---|
| `build: approved`、他は `pending` | 構築と検証まで実行。切替・後始末はスキップ → **成功で終了** |
| `switchover: approved` を追加 | 再実行。構築は冪等に no-op、検証を通り、**切替の承認が表示される** |
| `cleanup: approved` を追加 | 再実行。検証は「切替済みのため対象なし」で成功、**後始末の承認が表示される** |

手動承認は**その操作が config で承認されているときだけ表示される**。何も起きない承認をクリックする状況が生じないため、承認の形骸化を防げる。承認ゲートの実体は従来どおり config の `actions` にあり、運用は変わらない。

> ステージ条件（`BeforeEntry` の `Result: SKIP`）は比較的新しい CodePipeline の機能である。利用できない場合は `BeforeEntry` ブロックを削除すればよい。その場合、承認は毎回表示されるが、`pending` のアクションは CodeBuild 側で no-op するため動作自体は変わらない。

CodePipeline は `DetectChanges: false` のため、GitHub への push で自動開始しない。作業者は CloudFormation でスタックを作成後、`aws codepipeline start-pipeline-execution` または AWS Console から明示的に開始する。実行するスクリプトと buildspec は 2 つのテンプレートで共通である。

## Step 3〜5 の三つの実行方式

BuildGreen（Step 3）、VerifyGreen（Step 4）、Switchover（Step 5）は、実行目的に合わせて三つの経路で使用する。実行方式が違っても、各 Step が呼び出すシェルスクリプトと設定 YAML は共通である。

| 実行方式 | 主な用途 | 実行対象 | 起動元 |
|---|---|---|---|
| スクリプト直接ローカル実行 | 個別の AWS API 呼び出し・設定解析・判定ロジックの切り分け | `scripts/{build_green,verify_green,switchover}.sh` | シェルスクリプトを直接起動 |
| CodeBuild Local Agent | CodeBuild 実行前の buildspec・artifact・Docker・環境変数の互換性確認 | `ci/codebuild/{build-green,verify-green,switchover}.yml` | Local Agent 経由で buildspec を起動 |
| AWS CodeBuild / GitHub Actions | CI 上の継続的な検証 | CodeBuild buildspec / GitHub Actions workflow | リモート CI から起動 |

VerifyGreen のレポート生成器だけは、直接実行時に `GREEN_REPORT_GENERATOR` を指定しなければ Ruby を使う。一方、CodeBuild Local Agent、AWS CodeBuild、GitHub Actions は Docker Buildx で Go バイナリを作成して指定する。この違いはレポート生成器の実装・実行環境上の補足であり、検証対象・判定内容を変えるものではない。

スクリプト直接実行の全体フローは [直接実行による Blue/Green 移行フロー](../direct-blue-green-execution.md)、Local Agent の具体的な起動方法は [CodeBuild 各フローの単体ローカル検証](codebuild-local-verification.md) を参照する。

## 実行内容

| CodeBuild プロジェクト | buildspec | 既存スクリプト | 実行条件 |
|---|---|---|---|
| `ReadApprovalsProject` | `ci/codebuild/read-approvals.yml` | `scripts/read_action_approvals.sh` | AWS API を呼ばない。config を読むだけ |
| `PrecheckProject` | `ci/codebuild/precheck-target-parameter-group.yml` | `scripts/check_target_parameter_group.sh` | 読み取りのみ。常に実行 |
| `BuildGreenProject` | `ci/codebuild/build-green.yml` | `scripts/build_green.sh` | `actions.build: approved` の場合だけ作成 |
| `VerifyGreenProject` | `ci/codebuild/verify-green.yml` | `scripts/verify_green.sh` | 常に AWS API 検証を実行 |
| `SwitchoverProject` | `ci/codebuild/switchover.yml` | `scripts/switchover.sh` | 手動承認済みかつ `actions.switchover: approved` の場合だけ切替 |
| `CleanupProject` | `ci/codebuild/cleanup.yml` | `scripts/cleanup.sh` | 手動承認済みかつ `actions.cleanup: approved` の場合だけ削除 |

`PrecheckProject` と `CleanupProject` は [codepipeline-all-in-one.yml](../examples/rds-blue-green-deployment/codepipeline-all-in-one.yml) だけが定義する。既存の `codepipeline.yml` は BuildGreen / VerifyGreen / Switchover の 3 つのみである。

`VerifyGreenProject` の MySQL 実効値収集は、**設定ファイルの `mysql_verification` が制御する**（既定 `enabled: false` で Green DB へ接続しない）。パスワードの取得方法は `auth_method` で選ぶ。

| `auth_method` | 取得元 | ユーザー名の秘匿 | 用途 |
|---|---|---|---|
| `parameter_store` | SSM Parameter Store の SecureString | **必須。** `user_parameter_name` に別パラメータを指定する | **CI で使う方式。** カタログからの生成はこれに固定される |
| `plaintext` | 設定ファイルに直書き | 不可（config の `user` が必要） | **テスト環境専用**。`environment: production` では拒否される |
| `prompt` | MySQL クライアントの対話入力 | 不可（config の `user` が必要） | ローカル実行専用。CI では成立しない |

解決は `scripts/lib/mysql_credentials.sh` が行い、値はログ・コマンド引数・成果物へ出さず、`MYSQL_PWD` として MySQL クライアントのプロセスにだけ渡す。上表以外の値（`secrets_manager`、`iam` など）は不正な `auth_method` として拒否する。

**`parameter_store` ではユーザー名も必ず秘匿側へ置く。** `parameter_name`（パスワード）と `user_parameter_name`（ユーザー名）の両方が必須で、config の `user` は使わない。`plaintext` / `prompt` は秘匿側を持たないため config の `user` が必須である。

CFn の `MySqlCredentialsParameterArns` に、パスワード用とユーザー名用の 2 本の SSM パラメータ ARN をカンマ区切りで渡す。指定したときだけ `ssm:GetParameter` が `VerifyGreenRole` に付く。

Step 4 は Go レポート生成器を先にビルドし、`GREEN_REPORT_GENERATOR` として `verify_green.sh` に渡す。ビルド方法は実行基盤で異なる。

| 実行基盤 | ビルド方法 |
|---|---|
| CodeBuild | buildspec の `runtime-versions: golang` で**同一イメージ内**をビルドする（`go build ./scripts`）。Docker を使わないため `PrivilegedMode` は不要 |
| GitHub Actions | [Dockerfile.green-verification-report](Dockerfile.green-verification-report) をマルチステージビルドし、`.tools/green-report/` へ取り出す |

CodeBuild のイメージが提供する Go が `go.mod` の要求（`go 1.25`）より古い場合は、`GOTOOLCHAIN=auto`（Go 1.21 以降の既定）が必要なツールチェーンを取得する。VPC 内で実行する場合は、その取得経路も確保する。Ruby ランタイムは CodeBuild に不要である。

各 buildspec は設定 YAML を読むために `PyYAML==6.0.2` を導入する。ローカルで Step 3・4・5 のシェルスクリプトを実行する場合も、事前に `python3 -m pip install 'PyYAML==6.0.2'` を一度実行する。

JSON の読み取り・生成には `jq` を使う。CodeBuild の managed image と GitHub Actions のランナーには同梱されているため導入手順は無いが、ローカル実行では別途用意する（無ければ該当スクリプトが起動直後に明示エラーで停止する）。

実効値収集を有効にする場合は、CodeBuild プロジェクトを RDS に到達できるネットワークに配置する必要がある。テンプレートには VPC・サブネット・セキュリティグループを組み込んでいないため、組織の既存ネットワーク方針に従い `VerifyGreenProject` に `VpcConfig` を追加する。あわせて CodeBuild 実行ロールに対象 SSM パラメータの `ssm:GetParameter` と、KMS カスタマー管理キーを使う場合は `kms:Decrypt` を許可する。

## 2 つのテンプレート

| テンプレート | 作成するもの | 使いどころ |
|---|---|---|
| [codepipeline.yml](../examples/rds-blue-green-deployment/codepipeline.yml) | CodeBuild 3 つと CodePipeline。**S3 バケットと IAM ロールは既存リソースとして受け取る** | 組織側でロールを一元管理している場合 |
| [codepipeline-all-in-one.yml](../examples/rds-blue-green-deployment/codepipeline-all-in-one.yml) | **S3・IAM・CodeBuild 5 つ・CodePipeline のすべて** | 検証環境、スタック単位で権限を閉じたい場合 |

対象サービスの指定方法も異なる。

| | `codepipeline.yml` | `codepipeline-all-in-one.yml` |
|---|---|---|
| サービス指定 | **スタックパラメータ**（サービスごとに 1 スタック） | **パイプライン実行時の変数**（環境ごとに 1 スタックで複数サービスを扱える） |
| ステージ | Source → BuildGreen → VerifyGreen → 承認 → Switchover | Source → PrecheckPG → BuildGreen → VerifyGreen → 承認 → Switchover → 承認 → Cleanup |
| IAM の分割 | 全 Step で 1 ロール | **Step ごとに別ロール**（破壊的権限は Cleanup ロールのみ） |

## デプロイ例（自己完結版）

```bash
aws cloudformation deploy \
  --template-file examples/rds-blue-green-deployment/codepipeline-all-in-one.yml \
  --stack-name rds-bg-staging \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    PipelineNamePrefix=rds-bg \
    EnvironmentName=staging \
    DefaultServiceName=example-service \
    CodeStarConnectionArn=arn:aws:codeconnections:ap-northeast-1:123456789012:connection/xxxxxxxx \
    RepositoryId=your-org/your-repository \
    DbInstanceIdentifierPrefix=example-service-staging
```

IAM ロールを名前付きで作成するため `--capabilities CAPABILITY_NAMED_IAM` が必要である。

実行時に対象サービスを指定する。

```bash
aws codepipeline start-pipeline-execution \
  --name rds-bg-staging \
  --variables name=ServiceName,value=example-service
```

`--variables` を省略すると `DefaultServiceName` が使われる。

`DbInstanceIdentifierPrefix` は IAM の `Resource` を絞るために使う。既定の `*` のままだとアカウント内の全 DB インスタンスが変更権限の対象になるため、**実運用では必ず対象を絞る**。

## デプロイ例（既存ロールを使う版）

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
