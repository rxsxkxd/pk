# CodeBuild / CodePipeline 実行定義

CloudFormation で CodePipeline と CodeBuild プロジェクトを作成する。どちらのテンプレートも既存 S3 バケットを利用し、IAM ロールを既存にするかスタックで作るかで使い分ける（後述の「2 つのテンプレート」）。

デプロイ前に構成を確認する場合は [パイプライン構成図](codepipeline-structure.md) を参照する。ステージ・IAM 権限・実行シナリオをテンプレートの定義から起こしてある。

AWS 側に用意するリソース、IAM、ネットワーク、Secrets、デプロイ・実行手順は [CodeBuild / CodePipeline セットアップ手順](codebuild-codepipeline-setup.md) を参照する。

AWS 上の CodeBuild 実行時に限った外部接続先、接続条件、認証の解決方法は [CodeBuild 実環境の外部接続先と認証](codebuild-remote-external-access.md) を参照する。

Step 4 を「Go のビルド」と「検証の実行」に分け、実行側だけを RDS のある VPC 内へ置く構成の理由と要件は [Step 4 の分離と VPC 配置](verify-green-vpc-architecture.md) を参照する。図で追えるようにしてある。

その構成で必要になるセキュリティグループの具体的な設定は [VerifyGreen の セキュリティグループ設定](verify-green-security-group-setup.md) を参照する。**テンプレートは SG を作らない。**

CloudFormation の登録コマンドとパラメータの一覧は [codepipeline-all-in-one のデプロイとパラメータ一覧](codepipeline-all-in-one-parameters.md) にまとめてある。

Go のビルド（`BuildReportTool`）が失敗したときは [BuildReportTool の失敗切り分け](build-report-tool-troubleshooting.md) を参照する。**ログに何が出ていたら何をするか**を症状別にまとめてある。ローカルで実際に走らせて確かめる手順は [BuildReportTool のローカル検証手順](build-report-tool-local-verification.md) にある（新しい image は不要）。

各 CodeBuild buildspec を CodePipeline なしでローカル確認する手順は [CodeBuild 各フローの単体ローカル検証](codebuild-local-verification.md) を参照する。

```text
codepipeline.yml:
  Source (GitHub / CodeCommit) → BuildGreen → VerifyGreen → ManualApproval → Switchover
                               Step 3       Step 4          人の承認        Step 5

codepipeline-all-in-one.yml:
  Source (GitHub / CodeCommit) → ReadApprovals → PrecheckPG → BuildGreen → VerifyGreen
                             config を読む   構築前チェック  Step 3      Step 4
                                                                           切替前検証
    → [Switchover]  承認 → 切替          ※ actions.switchover が approved のときだけ入る

後始末（Step 7）はパイプラインに含まれない → tools/cleanup.sh を人が実行する
```

`[ ]` で囲んだステージには**入場条件**が付いている。`ReadApprovals` が config の `actions` をパイプライン変数として公開し、`BeforeEntry` の `VariableCheck` が `approved` でなければ**ステージごとスキップ**する。

このため 1 本のパイプラインを各フェーズで繰り返し実行できる。

| config の状態 | パイプラインの挙動 |
|---|---|
| `build: approved`、他は `pending` | 構築と検証まで実行。切替はスキップ → **成功で終了** |
| `switchover: approved` を追加 | 再実行。構築は冪等に no-op、検証を通り、**切替の承認が表示される** |
| 切替後 | 後始末は**パイプラインの外**で行う。`cleanup: approved` にして `tools/cleanup.sh` を実行する（作業者が破壊的権限を持つロールを引き受ける） |

手動承認は**その操作が config で承認されているときだけ表示される**。何も起きない承認をクリックする状況が生じないため、承認の形骸化を防げる。承認ゲートの実体は従来どおり config の `actions` にあり、運用は変わらない。

> ステージ条件（`BeforeEntry` の `Result: SKIP`）は比較的新しい CodePipeline の機能である。利用できない場合は `BeforeEntry` ブロックを削除すればよい。その場合、承認は毎回表示されるが、`pending` のアクションは CodeBuild 側で no-op するため動作自体は変わらない。

ソースの取得元は `SourceProvider` パラメータで `CodeConnections`（GitHub。既定）と `CodeCommit` を切り替える。**Source ステージのアクションと、CodePipeline ロールへ付く権限だけが入れ替わり、後続ステージはどちらも `SourceOutput` を受け取る。**CodePipeline は `DetectChanges: false`（CodeCommit では `PollForSourceChanges: false`）のため、push で自動開始しない。作業者は CloudFormation でスタックを作成後、`aws codepipeline start-pipeline-execution` または AWS Console から明示的に開始する。実行するスクリプトと buildspec は 2 つのテンプレートで共通である。

## Step 3〜5 の三つの実行方式

BuildGreen（Step 3）、VerifyGreen（Step 4）、Switchover（Step 5）は、実行目的に合わせて三つの経路で使用する。実行方式が違っても、各 Step が呼び出すシェルスクリプトと設定 YAML は共通である。

| 実行方式 | 主な用途 | 実行対象 | 起動元 |
|---|---|---|---|
| スクリプト直接ローカル実行 | 個別の AWS API 呼び出し・設定解析・判定ロジックの切り分け | `scripts/{build_green,verify_green,switchover}.sh` | シェルスクリプトを直接起動 |
| CodeBuild Local Agent | CodeBuild 実行前の buildspec・artifact・Docker・環境変数の互換性確認 | `ci/codebuild/{build-green,verify-green,switchover}.yml` | Local Agent 経由で buildspec を起動 |
| AWS CodeBuild / GitHub Actions | CI 上の継続的な検証 | CodeBuild buildspec / GitHub Actions workflow | リモート CI から起動 |

VerifyGreen のレポート生成器だけは、直接実行時に `GREEN_REPORT_GENERATOR` を指定しなければ Ruby を使う。一方、CodeBuild Local Agent、AWS CodeBuild、GitHub Actions は Docker Buildx で Go バイナリを作成して指定する。この違いはレポート生成器の実装・実行環境上の補足であり、検証対象・判定内容を変えるものではない。

スクリプト直接実行の全体フローは [直接実行による Blue/Green 移行フロー](../docs/direct-blue-green-execution.md)、Local Agent の具体的な起動方法は [CodeBuild 各フローの単体ローカル検証](codebuild-local-verification.md) を参照する。

## 実行内容

| CodeBuild プロジェクト | buildspec | 既存スクリプト | 実行条件 |
|---|---|---|---|
| `ReadApprovalsProject` | `ci/codebuild/read-approvals.yml` | `scripts/read_action_approvals.sh` | AWS API を呼ばない。config を読むだけ |
| `PrecheckProject` | `ci/codebuild/precheck-target-parameter-group.yml` | `scripts/check_target_parameter_group.sh` | **構築前チェック。**読み取りのみ。常に実行 |
| `BuildGreenProject` | `ci/codebuild/build-green.yml` | `scripts/build_green.sh` | `actions.build: approved` の場合だけ作成 |
| `BuildReportToolProject` | `ci/codebuild/build-report-tool.yml` | — | Step 4 の Go レポート生成器をビルドするだけ。AWS API を呼ばない。**外部ネットワークへ出るのはここだけ** |
| `VerifyGreenProject` | `ci/codebuild/verify-green.yml` | `scripts/verify_green.sh` | 常に AWS API 検証を実行 |
| `SwitchoverProject` | `ci/codebuild/switchover.yml` | `scripts/switchover.sh` | 手動承認済みかつ `actions.switchover: approved` の場合だけ切替 |

`PrecheckProject` は [codepipeline-all-in-one.yml](../examples/rds-blue-green-deployment/codepipeline-all-in-one.yml) だけが定義する。既存の `codepipeline.yml` は BuildGreen / VerifyGreen / Switchover の 3 つのみである。

`VerifyGreenProject` の MySQL 実効値収集は、**設定ファイルの `mysql_verification` が制御する**（既定 `enabled: false` で Green DB へ接続しない）。パスワードの取得方法は `auth_method` で選ぶ。

| `auth_method` | 取得元 | ユーザー名の秘匿 | 用途 |
|---|---|---|---|
| `parameter_store` | SSM Parameter Store の SecureString | **必須。** `user_parameter_name` に別パラメータを指定する | **CI で使う方式。** カタログからの生成はこれに固定される |
| `plaintext` | 設定ファイルに直書き | 不可（config の `user` が必要） | **テスト環境専用**。`environment: production` では拒否される |
| `prompt` | シェルの対話入力（エコーしない） | 不可（config の `user` が必要） | ローカル実行専用。CI では成立しない |

`BuildReportTool` は `scripts/resolve_go_module_root.sh` で Go モジュールルートを突き止め、**期待する構成になっているかを先に検査する**（`go.mod` の位置・重複・ビルド対象のソースと `go.sum` の有無）。外れていれば `構成が…` で始まるメッセージを出して停止し、黙って別のものをビルドしない。

Step 4 が使うビルド済みバイナリ 3 本（AWS の状態収集・DB の実効値収集・判定とレポート）の場所は `scripts/lib/resolve_green_tools.rb` が決める。呼び出し側の指定 → `BuildReportTool` の artifact → ソースツリー の順に探し、見つからなければ理由と探索先を出して停止する（**ビルドはしない**）。

解決は `scripts/lib/mysql_credentials.sh` が行い、値はログ・コマンド引数・成果物へ出さず、環境変数で実効値収集バイナリのプロセスにだけ渡す。上表以外の値（`secrets_manager`、`iam` など）は不正な `auth_method` として拒否する。

**`parameter_store` ではユーザー名も必ず秘匿側へ置く。** `parameter_name`（パスワード）と `user_parameter_name`（ユーザー名）の両方が必須で、config の `user` は使わない。`plaintext` / `prompt` は秘匿側を持たないため config の `user` が必須である。

CFn の `MySqlCredentialsParameterPath` に、SSM パラメータを置いた**階層**（例 `/rds-bg/staging`）を渡す。指定したときだけ、その配下への `ssm:GetParameter` が `VerifyGreenRole` に付く。

Step 4 は Go レポート生成器を先にビルドし、`GREEN_REPORT_GENERATOR` として `verify_green.sh` に渡す。

**リモートでは MySQL へ接続しない構成を前提にできる。**Green DB へ到達するには CodeBuild を VPC 内へ配置する必要があり、それが運用上難しい場合は `mysql_verification.enabled: false` のまま AWS API による検証だけを行う。MySQL 実効値を含めた確認はローカルから実施する。**同じレポート生成器が両方を賄い**、実効値が無い場合はレポートの該当列が `未収集` になるだけである（判定は AWS API の値で行うため内容は変わらない）。方針は [decisions/implementation-language-policy.md](../docs/decisions/implementation-language-policy.md) にある。

ビルド方法は実行基盤で異なる。

| 実行基盤 | ビルド方法 |
|---|---|
| CodeBuild | **ビルドと実行を別ステージに分けている。**`BuildReportTool` が `scripts/` 配下の 2 コマンドを `go build` し（`go.mod` のあるディレクトリを自力で突き止めてから実行する。理由は buildspec のコメント）、バイナリを artifact（`ReportToolOutput`）として出す。`VerifyGreen` はそれを 2 つ目の input artifact として受け取り、`CODEBUILD_SRC_DIR_ReportToolOutput` から実行する。**VerifyGreen は Go も外部ネットワークも必要としない。**VPC 内へ入れるのは `VerifyGreen` だけで（`VpcId` / `VerifyGreenSubnetIds`）、**`BuildReportTool` は他の VPC 外プロジェクトと同じく VPC の外で動く**。Docker を使わないため `PrivilegedMode` も不要 |
| GitHub Actions | ランナー同梱の Go で `go build ./scripts/generate_green_verification_report`（CodeBuild と同じ手順。Docker は使わない） |

CodeBuild のイメージが提供する Go が `go.mod` の要求（`go 1.25`）より古い場合は、`GOTOOLCHAIN=auto`（Go 1.21 以降の既定）が必要なツールチェーンを取得する。VPC 内で実行する場合は、その取得経路も確保する。Ruby ランタイムは CodeBuild に不要である。

各 buildspec は設定 YAML を読むために、install フェーズで `rbenv local 3.4.10` を実行して Ruby を選ぶ（CodeBuild image 同梱の rbenv を使う。`rbenv` が無い環境では何もしない）。**YAML / JSON は Ruby の標準ライブラリなので、パッケージの追加導入は無く、PyPI へも到達しない。**ローカルで Step 3・4・5 のシェルスクリプトを実行する場合も、Ruby があれば追加作業は要らない。

設定 YAML の読み取りは `scripts/lib/deployment_config.rb` が **Ruby の標準ライブラリ（psych）**で行い、各スクリプトは取り出す項目だけを宣言する（`変数名=種別:パス[=既定値]`）。AWS CLI の応答（JSON）の取り出しには `jq` を使う。CodeBuild の managed image と GitHub Actions のランナーには jq が同梱されているため導入手順は無いが、ローカル実行では別途用意する（無ければ該当スクリプトが起動直後に明示エラーで停止する）。

実効値収集を有効にする場合は、`VerifyGreenProject` を RDS に到達できるネットワークへ配置する。**テンプレートは `VpcId` / `VerifyGreenSubnetIds` / `VerifyGreenSecurityGroupIds` を受け取って `VpcConfig` を組む**（セキュリティグループは作らないので別途用意する。[設定手順](verify-green-security-group-setup.md)）。

接続情報は **SSM Parameter Store の 2 本**（パスワードとユーザー名）から取る。**どのパラメータを読むかは config の `mysql_verification`（`parameter_name` / `user_parameter_name`）が決め、サービスごとに変えられる。**CloudFormation の `MySqlCredentialsParameterPath` は `ssm:GetParameter` を許す階層であって、読む名前を決めるものではない。SecureString をカスタマー管理キーで暗号化している場合は `MySqlCredentialsKmsKeyArn` も渡す（AWS 管理キーなら不要）。パイプラインは環境ごとに 1 本なので、**その環境の全サービスのパラメータを同じ階層の下に置く**（サービスを増やしてもスタック更新は要らない）。詳細と設定例は [セットアップ手順](codebuild-codepipeline-setup.md) にある。

## 2 つのテンプレート

| テンプレート | 作成するもの | 使いどころ |
|---|---|---|
| [codepipeline.yml](../examples/rds-blue-green-deployment/codepipeline.yml) | CodeBuild 3 つと CodePipeline。**S3 バケットと IAM ロールは既存リソースとして受け取る** | 組織側でロールを一元管理している場合 |
| [codepipeline-all-in-one.yml](../examples/rds-blue-green-deployment/codepipeline-all-in-one.yml) | **既存 S3 を利用**し、IAM・CodeBuild 5 つ・CodePipeline を作成 | 検証環境、スタック単位で権限を閉じたい場合 |

対象サービスの指定方法も異なる。

| | `codepipeline.yml` | `codepipeline-all-in-one.yml` |
|---|---|---|
| サービス指定 | **スタックパラメータ**（サービスごとに 1 スタック） | **パイプライン実行時の変数**（環境ごとに 1 スタックで複数サービスを扱える） |
| ステージ | Source → BuildGreen → VerifyGreen → 承認 → Switchover | Source → PrecheckPG → BuildGreen → VerifyGreen → 承認 → Switchover |
| IAM の分割 | 全 Step で 1 ロール | **Step ごとに別ロール**（破壊的権限を持つロールは無い） |

## デプロイ例（IAM・CI 作成版）

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
    "ProtectedRdsResourceArns=arn:aws:rds:ap-northeast-1:123456789012:db:example-service-staging*,arn:aws:rds:ap-northeast-1:123456789012:snapshot:example-service-staging*"
```

IAM ロールを名前付きで作成するため `--capabilities CAPABILITY_NAMED_IAM` が必要である。

実行時に対象サービスを指定する。

```bash
aws codepipeline start-pipeline-execution \
  --name rds-bg-staging \
  --variables name=ServiceName,value=example-service
```

`--variables` を省略すると `DefaultServiceName` が使われる。

`ProtectedRdsResourceArns` は RDS の変更権限（保護スナップショットの作成）の `Resource` を絞るために使う。**カンマ区切りで複数指定でき**、`db` と `snapshot` の両方を入れる必要がある。空のままだとアカウント・リージョン内の全 DB インスタンスとスナップショットが対象になるため、**実運用では必ず対象を絞る**。`*` 1 つでも動作するが推奨しない。

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

`CodeStarConnectionArn` は事前に GitHub と接続して `AVAILABLE` にした CodeConnections 接続を指定する。ロールはテンプレート外で管理し、最小権限で作成する。CodeBuild 実行ロールに必要な RDS 権限は [upgrade-flow-steps.md](../docs/upgrade-flow-steps.md) の「CI 実行ロールに必要な権限」を参照する。
