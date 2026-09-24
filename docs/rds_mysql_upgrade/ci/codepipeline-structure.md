# パイプライン構成図（デプロイ前の確認用）

[codepipeline-all-in-one.yml](../examples/rds-blue-green-deployment/codepipeline-all-in-one.yml) が作る構成を、デプロイせずに確認するための資料である。本書の内容はテンプレートの定義から起こしており、**テンプレートを変更したら本書も更新する。**

作成されるリソースは 15 個である。アーティファクト用 S3 バケットは既存のものをパラメータで受け取り、このスタックでは作成・変更しない。

| 種別 | 数 |
|---|---|
| `AWS::IAM::ManagedPolicy` | 1 |
| `AWS::IAM::Role` | 7（CodeBuild 6 + CodePipeline 1） |
| `AWS::CodeBuild::Project` | 6 |
| `AWS::CodePipeline::Pipeline` | 1 |

## 全体像

```
                          ┌──────────────────────────────────┐
   aws codepipeline       │  CodePipeline (V2)               │
   start-pipeline-        │  rds-bg-<env>                    │
   execution              │  変数: ServiceName               │
   --variables ─────────► │                                  │
     ServiceName=...      └──────────────────────────────────┘
                                        │
   ┌────────────────────────────────────┴────────────────────────────────────┐
   │                                                                          │
   ▼                                                                          ▼
┌─────────────────────────────────────────┐                    ┌──────────────────────┐
│ 1. Source                               │                    │ 既存 S3 アーティファクト │
│  Source: GitHub または CodeCommit       │───► SourceOutput ─►│ ArtifactBucketName   │
│    DetectChanges: false（push で起動せず）│                    │ （既存バケット名）   │
└─────────────────────────────────────────┘                    │ 組織の既存設定を利用 │
   │                                                            │ （同一リージョン）   │
   ▼                                                            │                     │
┌─────────────────────────────────────────┐                    └──────────────────────┘
│ 2. ReadApprovals        Namespace: Approvals                 │
│    config の actions を読み、変数として公開                    │
│    → BUILD_APPROVED / SWITCHOVER_APPROVED / CLEANUP_APPROVED │
└─────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────┐
│ 3. PrecheckParameterGroup                │  構築前チェック: 8.4 パラメータグループの存在と family
└─────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────┐
│ 4. BuildGreen               [Step 3]     │  保護スナップショット → Blue/Green 作成
│    timeout 120 分                        │  actions.build が pending なら no-op
└─────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────┐
│ 5. VerifyGreen              [Step 4]     │  切替前検証: Green 構成 + ReplicaLag の検証
│    Go は BuildReportTool が事前ビルド     │  切替後は「対象なし」で成功
└─────────────────────────────────────────┘
   │
   ▼
╔═════════════════════════════════════════╗
║ 6. Switchover               [Step 5]     ║  ◄── 入場条件
║    ┌───────────────────────────────────┐ ║      #{Approvals.SWITCHOVER_APPROVED}
║    │ RunOrder 1: ManualApproval        │ ║      == "approved" でなければ
║    │ RunOrder 2: Switchover (CodeBuild)│ ║      ステージごと SKIP
║    └───────────────────────────────────┘ ║
╚═════════════════════════════════════════╝
   │
   ▼
╔═════════════════════════════════════════╗
║ 7. Cleanup                  [Step 7]     ║  ◄── 入場条件
║    ┌───────────────────────────────────┐ ║      #{Approvals.CLEANUP_APPROVED}
║    │ RunOrder 1: ManualApproval        │ ║      == "approved" でなければ
║    │ RunOrder 2: Cleanup (CodeBuild)   │ ║      ステージごと SKIP
║    └───────────────────────────────────┘ ║
╚═════════════════════════════════════════╝
```

二重線のステージには **`BeforeEntry` 条件（`VariableCheck` / `Result: SKIP`）** が付いている。config が承認していないフェーズは、手動承認を含めてステージごと飛ばされる。

## ステージ一覧

| # | ステージ | アクション | 入場条件 | 変更操作 |
|---|---|---|---|---|
| 1 | `Source` | `SourceFromGitHub` または `SourceFromCodeCommit`（`SourceProvider` で切り替え） | なし | なし |
| 2 | `ReadApprovals` | `ReadApprovals` | なし | なし（config を読むだけ） |
| 3 | `PrecheckParameterGroup`（構築前チェック） | `PrecheckParameterGroup` | なし | なし（読み取り API のみ） |
| 4 | `BuildGreen` | `BuildGreen` | なし | **あり**（`actions.build` が `approved` のときのみ） |
| 5 | `VerifyGreen`（切替前検証） | `VerifyGreen` | なし | なし |
| 6 | `Switchover` | `ManualApproval` → `Switchover` | `SWITCHOVER_APPROVED == approved` | **あり・本番影響** |

**Step 7（後始末）はパイプラインに含まれない。**旧 Blue の削除は不可逆で、切り戻し不要の判断や逆方向レプリケーションの確認と一体で行うべき作業のため、人がツール `tools/cleanup.sh` で実行する（手順は [移行の実行](../operations-migration-run.md) の B-4）。

## 実行シナリオ

同じパイプラインを各フェーズで繰り返し実行する。**config の宣言が進むほど、通過するステージが増える。**

### 1 回目: 構築フェーズ（`build: approved`、他は `pending`）

```
Source ✓ → ReadApprovals ✓ → PrecheckPG ✓ → BuildGreen ✓ → VerifyGreen ✓
  → Switchover [SKIP]                                           ⇒ 成功で終了
```

Blue/Green が作成され、検証まで完了する。切替はステージごと飛ばされるため、**承認ボタンは表示されない。**

### 2 回目: 切替フェーズ（`switchover: approved` を追加）

```
Source ✓ → ReadApprovals ✓ → PrecheckPG ✓ → BuildGreen ✓(no-op) → VerifyGreen ✓
  → Switchover ▶ 承認待ち → 切替実行 ✓                          ⇒ 成功で終了
```

`BuildGreen` は既に `AVAILABLE` な Deployment があるため何もせず成功する（冪等）。切替ステージに入り、**ここで初めて承認が表示される。**

### 切替後にもう一度実行した場合

```
Source ✓ → ReadApprovals ✓ → PrecheckPG ✓ → BuildGreen ✓(no-op) → VerifyGreen ✓(対象なし)
  → Switchover ▶ 承認待ち → 切替 ✓(完了済み)                    ⇒ 成功で終了
```

`BuildGreen` と `Switchover` は移行元が既に 8.4 であることを検出して何もしない。`VerifyGreen` も「切替済みのため検証対象なし」で成功する。後始末はこの後、パイプラインの外で `tools/cleanup.sh` を実行する。

> **待機時間はパイプラインの外にある。** 構築から切替まで数週間空いても、その間パイプラインは実行されていない。CodePipeline の手動承認は既定 7 日でタイムアウトするが、承認が表示されるのは「そのフェーズを実行しに来たとき」だけなので問題にならない。

## CodeBuild プロジェクト

| プロジェクト | buildspec | 実行するスクリプト | 特記 |
|---|---|---|---|
| `ReadApprovalsProject` | `read-approvals.yml` | `read_action_approvals.sh` | AWS API を呼ばない |
| `PrecheckProject` | `precheck-target-parameter-group.yml` | `check_target_parameter_group.sh` | 読み取りのみ |
| `BuildGreenProject` | `build-green.yml` | `build_green.sh` | **timeout 120 分**（Green の作成待ち） |
| `BuildReportToolProject` | `build-report-tool.yml` | — | Go レポート生成器をビルドし artifact へ出す。AWS API を呼ばない。**外部ネットワークへ出るのはここだけ** |
| `VerifyGreenProject` | `verify-green.yml` | `verify_green.sh` | artifact のバイナリを使うだけ。**Go も外部ネットワークも不要**（`PrivilegedMode` も不要） |
| `SwitchoverProject` | `switchover.yml` | `switchover.sh` | **timeout 60 分**（切替完了待ち） |

全プロジェクトで `Image: aws/codebuild/standard:7.0`、`ComputeType: BUILD_GENERAL1_SMALL`。

### 環境変数

| 変数 | 与え方 |
|---|---|
| `CONFIG_FILE` | プロジェクト定義で固定（`config/blue-green/<env>.deployment.yml`） |
| `SERVICE_NAME` | **アクション側で上書き**（`#{variables.ServiceName}`）。プロジェクト定義には既定値を置くため `start-build` 単体でも動く |
| `COLLECT_MYSQL_RUNTIME_VALUES` | `VerifyGreenProject` のみ。スタックパラメータから |

## IAM 権限

全 CodeBuild ロールが共通ポリシー（ログ出力・アーティファクト読み書き・RDS の `Describe*`・CloudWatch の `GetMetricStatistics`）を持ち、**変更権限だけをロールごとに分ける。**

| ロール | 共通ポリシーに加えて持つ権限 |
|---|---|
| `ReadApprovalsRole` | なし |
| `PrecheckRole` | なし |
| `BuildGreenRole` | `rds:CreateDBSnapshot` / `rds:CreateBlueGreenDeployment` / `rds:AddTagsToResource` |
| `VerifyGreenRole` | `ssm:GetParameter` / `ssm:GetParameters`（`MySqlCredentialsParameterPath` 指定時のみ。対象はその階層の配下） |
| `SwitchoverRole` | `rds:SwitchoverBlueGreenDeployment`（`deployment:*`）、`rds:ModifyDBInstance`／`rds:PromoteReadReplica`（`db:*`） |
**破壊的権限（`rds:DeleteDBInstance` / `rds:DeleteBlueGreenDeployment`）はどのロールも持たない。**このスタックが作るロールでは旧 Blue を削除できない。後始末は `tools/cleanup.sh` を作業者が実行し、そのとき作業者がこの権限を持つロールを引き受ける。

`CodePipelineRole` はアーティファクトの読み書き、6 プロジェクト（ReadApprovals / Precheck / BuildGreen / BuildReportTool / VerifyGreen / Switchover）の `StartBuild`、`codestar-connections:UseConnection`、（指定時のみ）`sns:Publish` を持つ。

### リソースの絞り込み

RDS の変更権限は `ProtectedRdsResourceArns` で ARN を絞る（カンマ区切りで複数指定できる）。

```
arn:aws:rds:<region>:<account>:db:<識別子の接頭辞>*
arn:aws:rds:<region>:<account>:snapshot:<識別子の接頭辞>*
（db と snapshot の両方が必要。未指定なら db:* と snapshot:* へ落ちる）
```

**既定値は `*` である。** そのままだとアカウント内の全 DB インスタンスが対象になるため、実運用では必ず指定する（例: `example-service-production`）。

`Describe*` 系はリソースレベル制御に対応しない API があるため `Resource: '*'` としている。読み取りのみで変更操作は含まない。

## S3 アーティファクト

`codepipeline-all-in-one.yml` は **`ArtifactBucketName` を空にすると S3 バケットを新規作成する**（バージョニング有効、SSE-S3、パブリックアクセス全ブロック、非 TLS 拒否、保持日数経過で失効。`DeletionPolicy: Retain`）。名前は `<PipelineNamePrefix>-<EnvironmentName>-artifacts-<AccountId>-<Region>` で、スタックの出力 `ArtifactBucket` に出る。

既存バケットを使う場合は `ArtifactBucketName` に、CodePipeline と同一リージョンにあるバケット名を指定する。このときテンプレートは `AWS::S3::Bucket` と `AWS::S3::BucketPolicy` を作成せず、既存バケットの暗号化、パブリックアクセスブロック、ライフサイクル、バケットポリシーを変更しない。組織のバケットポリシーで明示許可している場合は、作成される `CodePipelineRole` と各 CodeBuild ロールからの読み書きを許可しておく。`codepipeline.yml`（役割分担の都合でバケットを作らない版）は常に既存バケットが必須である。

各 CodeBuild は `artifacts/` 配下の応答 JSON と検証レポートを出力し、次ステージへは渡さず既存バケットに蓄積する。

## デプロイ前の確認方法

```sh
# 静的検査（構文・プロパティ・型）
cfn-lint examples/rds-blue-green-deployment/codepipeline-all-in-one.yml

# AWS 側での検証（認証情報が必要。リソースは作られない）
aws cloudformation validate-template \
  --template-body file://examples/rds-blue-green-deployment/codepipeline-all-in-one.yml

# 変更セットで「何が作られるか」を確認してから実行する
aws cloudformation create-change-set \
  --stack-name rds-bg-staging --change-set-name review \
  --template-body file://examples/rds-blue-green-deployment/codepipeline-all-in-one.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=EnvironmentName,ParameterValue=staging ...
aws cloudformation describe-change-set \
  --stack-name rds-bg-staging --change-set-name review \
  --query 'Changes[].ResourceChange.[Action,ResourceType,LogicalResourceId]' --output table
```

## 未検証の箇所

AWS 環境がないため、以下は `cfn-lint` とドキュメントの確認までしか行っていない。

- **ステージ条件（`BeforeEntry` の `Result: SKIP`）の実挙動。** 比較的新しい機能である。利用できない場合は `BeforeEntry` ブロックを削除すればよい。承認は毎回表示されるようになるが、`pending` のアクションは CodeBuild 側で no-op するため動作自体は変わらない
- **CodeBuild の `exported-variables` がステージ条件から参照できること。** `#{Approvals.SWITCHOVER_APPROVED}` の解決
- IAM の ARN 絞り込みが実 API で十分か（特に `CreateBlueGreenDeployment` の対象リソース）

## 関連ドキュメント

- [README.md](README.md) — 2 つのテンプレートの使い分けとデプロイ例
- [codebuild-codepipeline-setup.md](codebuild-codepipeline-setup.md) — AWS 側の事前準備
- [upgrade-flow-steps.md](../docs/upgrade-flow-steps.md) — Step 1〜7 の分割と承認モデル
- [decisions/idempotency-strategy.md](../docs/decisions/idempotency-strategy.md) — 各ステージが再実行安全である根拠
