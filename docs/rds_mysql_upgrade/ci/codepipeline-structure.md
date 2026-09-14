# パイプライン構成図（デプロイ前の確認用）

[codepipeline-all-in-one.yml](../examples/rds-blue-green-deployment/codepipeline-all-in-one.yml) が作る構成を、デプロイせずに確認するための資料である。本書の内容はテンプレートの定義から起こしており、**テンプレートを変更したら本書も更新する。**

作成されるリソースは 17 個である。

| 種別 | 数 |
|---|---|
| `AWS::S3::Bucket` / `BucketPolicy` | 1 / 1 |
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
│ 1. Source                               │                    │ S3 アーティファクト  │
│    CodeStarSourceConnection (GitHub)    │───► SourceOutput ─►│ <prefix>-<env>-      │
│    DetectChanges: false（push で起動せず）│                    │ artifacts-<acct>-... │
└─────────────────────────────────────────┘                    │  暗号化 / 版管理 /   │
   │                                                            │  公開ブロック /      │
   ▼                                                            │  TLS 強制 / 365 日   │
┌─────────────────────────────────────────┐                    └──────────────────────┘
│ 2. ReadApprovals        Namespace: Approvals                 │
│    config の actions を読み、変数として公開                    │
│    → BUILD_APPROVED / SWITCHOVER_APPROVED / CLEANUP_APPROVED │
└─────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────┐
│ 3. PrecheckParameterGroup   [Step 2 確認]│  8.4 パラメータグループの存在と family
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
│ 5. VerifyGreen              [Step 4]     │  Green 構成 + ReplicaLag の検証
│    Go は runtime-versions でビルド        │  切替後は「対象なし」で成功
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
| 1 | `Source` | `SourceFromGitHub` | なし | なし |
| 2 | `ReadApprovals` | `ReadApprovals` | なし | なし（config を読むだけ） |
| 3 | `PrecheckParameterGroup` | `PrecheckParameterGroup` | なし | なし（読み取り API のみ） |
| 4 | `BuildGreen` | `BuildGreen` | なし | **あり**（`actions.build` が `approved` のときのみ） |
| 5 | `VerifyGreen` | `VerifyGreen` | なし | なし |
| 6 | `Switchover` | `ManualApproval` → `Switchover` | `SWITCHOVER_APPROVED == approved` | **あり・本番影響** |
| 7 | `Cleanup` | `ManualApproval` → `Cleanup` | `CLEANUP_APPROVED == approved` | **あり・不可逆** |

## 実行シナリオ

同じパイプラインを各フェーズで繰り返し実行する。**config の宣言が進むほど、通過するステージが増える。**

### 1 回目: 構築フェーズ（`build: approved`、他は `pending`）

```
Source ✓ → ReadApprovals ✓ → PrecheckPG ✓ → BuildGreen ✓ → VerifyGreen ✓
  → Switchover [SKIP]  → Cleanup [SKIP]                        ⇒ 成功で終了
```

Blue/Green が作成され、検証まで完了する。切替と後始末はステージごと飛ばされるため、**承認ボタンは表示されない。**

### 2 回目: 切替フェーズ（`switchover: approved` を追加）

```
Source ✓ → ReadApprovals ✓ → PrecheckPG ✓ → BuildGreen ✓(no-op) → VerifyGreen ✓
  → Switchover ▶ 承認待ち → 切替実行 ✓ → Cleanup [SKIP]         ⇒ 成功で終了
```

`BuildGreen` は既に `AVAILABLE` な Deployment があるため何もせず成功する（冪等）。切替ステージに入り、**ここで初めて承認が表示される。**

### 3 回目: 後始末フェーズ（`cleanup: approved` を追加）

```
Source ✓ → ReadApprovals ✓ → PrecheckPG ✓ → BuildGreen ✓(no-op) → VerifyGreen ✓(対象なし)
  → Switchover ▶ 承認待ち → 切替 ✓(完了済み) → Cleanup ▶ 承認待ち → 削除実行 ✓
```

`BuildGreen` と `Switchover` は移行元が既に 8.4 であることを検出して何もしない。`VerifyGreen` も「切替済みのため検証対象なし」で成功する。

> **待機時間はパイプラインの外にある。** 構築から切替まで数週間空いても、その間パイプラインは実行されていない。CodePipeline の手動承認は既定 7 日でタイムアウトするが、承認が表示されるのは「そのフェーズを実行しに来たとき」だけなので問題にならない。

## CodeBuild プロジェクト

| プロジェクト | buildspec | 実行するスクリプト | 特記 |
|---|---|---|---|
| `ReadApprovalsProject` | `read-approvals.yml` | `read_action_approvals.sh` | AWS API を呼ばない |
| `PrecheckProject` | `precheck-target-parameter-group.yml` | `check_target_parameter_group.sh` | 読み取りのみ |
| `BuildGreenProject` | `build-green.yml` | `build_green.sh` | **timeout 120 分**（Green の作成待ち） |
| `VerifyGreenProject` | `verify-green.yml` | `verify_green.sh` | Go レポート生成器を `runtime-versions: golang` で同一イメージ内ビルド（`PrivilegedMode` 不要） |
| `SwitchoverProject` | `switchover.yml` | `switchover.sh` | **timeout 60 分**（切替完了待ち） |
| `CleanupProject` | `cleanup.yml` | `cleanup.sh` | 既定 60 分 |

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
| `VerifyGreenRole` | `ssm:GetParameter` / `ssm:GetParameters`（`MySqlCredentialsParameterArns` 指定時のみ付与） |
| `SwitchoverRole` | `rds:SwitchoverBlueGreenDeployment` |
| **`CleanupRole`** | **`rds:DeleteDBInstance` / `rds:DeleteBlueGreenDeployment` / `rds:ModifyDBInstance`** / `rds:CreateDBSnapshot` / `rds:AddTagsToResource` |

**破壊的権限は `CleanupRole` にのみ存在する。** 他のロールでは旧 Blue を削除できない。

`CodePipelineRole` はアーティファクトの読み書き、6 プロジェクトの `StartBuild`、`codestar-connections:UseConnection`、（指定時のみ）`sns:Publish` を持つ。

### リソースの絞り込み

RDS の変更権限は `DbInstanceIdentifierPrefix` で ARN を絞る。

```
arn:aws:rds:<region>:<account>:db:<DbInstanceIdentifierPrefix>*
arn:aws:rds:<region>:<account>:snapshot:<DbInstanceIdentifierPrefix>*
```

**既定値は `*` である。** そのままだとアカウント内の全 DB インスタンスが対象になるため、実運用では必ず指定する（例: `example-service-production`）。

`Describe*` 系はリソースレベル制御に対応しない API があるため `Resource: '*'` としている。読み取りのみで変更操作は含まない。

## S3 アーティファクト

```
<PipelineNamePrefix>-<EnvironmentName>-artifacts-<AccountId>-<Region>
```

| 設定 | 値 |
|---|---|
| 暗号化 | SSE-S3（AES256） |
| パブリックアクセス | 4 項目すべてブロック |
| バージョニング | 有効 |
| バケットポリシー | 非 TLS 通信を `Deny` |
| ライフサイクル | 365 日で失効、旧版は 90 日、未完了マルチパートは 7 日 |
| 削除時 | **`DeletionPolicy: Retain`**（移行の証跡が残るためスタック削除でも消えない） |

各 CodeBuild は `artifacts/` 配下の応答 JSON と検証レポートを出力し、次ステージへは渡さず S3 に蓄積する。

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
- [upgrade-flow-steps.md](../upgrade-flow-steps.md) — Step 1〜7 の分割と承認モデル
- [decisions/idempotency-strategy.md](../decisions/idempotency-strategy.md) — 各ステージが再実行安全である根拠
