# 確認手順書: AMI 公開パイプラインの稼働環境での確認

> スコープ: [`ami-publish/`](./ami-publish/README.md) を実際の AWS 環境（まずは開発アカウント）にデプロイし、動作を確認するまでに担当者が行う作業と、その確認手順。開発計画の M5〜M7 のうち、稼働環境が必要な部分
>
> スコープ外: コードの修正、AWS を使わない確認（済み。[検証状況](./ami-publish/README.md#検証状況)）
>
> 関連: [開発計画: AMI 作成以降](./ami-publish-development-plan.md) / 失敗したときは [トラブルシューティング](./ami-publish-troubleshooting.md) / リリース用インスタンスのロールの許可は [リリース用インスタンスの IAM ロール](./ami-publish-release-instance-iam.md)

## 残っている作業の一覧

AWS を使わない確認（生成・テスト・`cfn-lint`・Docker での buildspec の再現）は済んでいる。残りはすべて稼働環境が必要な作業である。

| # | 作業 | 内容 | 開発計画 |
|---|---|---|---|
| 0 | 前提の決定 | ソースにするリポジトリの用意（**必須。下記の注意を参照**） | D2 |
| 1 | AWS 側の事前準備 | リリース用インスタンス、セキュリティグループ、CodeConnections の接続 | M2・M5 |
| 2 | 設定値の記入と再生成 | `config/ami_publish.yml` のダミーの値を実際の値に置き換え、生成・レビューする | M2・M5 |
| 3 | 仕組みのデプロイ | 3 つのスタックを AWS CLI でデプロイする | M2・M5 |
| 4 | デプロイ結果の確認 | スタック・SSM ドキュメント・起動テンプレート・パイプラインの確認、ヘルスチェックの単体実行、`plan` | M5 |
| 5 | 初回の AMI 公開 | パイプラインを実行し、AMI と起動テンプレートの新しいバージョンができることを確認する | M5・M6 |
| 6 | 障害試験 | ヘルスチェック失敗、再実行、同時実行、ロールバック など | M6 |
| 7 | 後片付けと記録 | 試験で作った AMI・スナップショットの削除、結果の記録 | M6・M7 |

## 0. 前提の決定: ソースにするリポジトリ

AMI 公開パイプラインは、CodeConnections でリポジトリを取得し、**リポジトリのルートにある** `generated/codebuild/ami-publish-buildspec.yml` と `Gemfile` を使う（生成された定義がそう書かれている）。

現在のコードは `pk` リポジトリの `docs/ec2/ami-publish/` にあるため、`pk` リポジトリをそのままソースにすると、buildspec もツールも見つからずに失敗する。次のどちらかを選ぶ。

| 方法 | 内容 |
|---|---|
| **(a) 別リポジトリにする（推奨。決定事項 D2 のとおり）** | `docs/ec2/ami-publish/` の中身をルートとするリポジトリを作る（例: `example-org/ami-publish`）。コードの修正は不要 |
| (b) `pk` リポジトリをソースにする | buildspec のパスと、buildspec 内でのディレクトリ移動（`cd docs/ec2/ami-publish`）を生成ツールで扱えるようにする修正が必要 |

(b) にする場合は、先にコードの修正を依頼する。以降は (a) を前提とする。

## 1. AWS 側の事前準備

これらのスタックは次のものを**作らない**。事前に用意する。

| 準備するもの | 条件 | 確認コマンド |
|---|---|---|
| リリース用インスタンス | 起動中。インスタンスプロファイルに `AmazonSSMManagedInstanceCore`。SSM Agent が接続済み | `aws ssm describe-instance-information --filters Key=InstanceIds,Values=<ID> --query 'InstanceInformationList[0].PingStatus'` → `Online` |
| 〃 アプリの状態 | リリースバージョンが配置・起動済みで、`curl http://localhost/up` が成功する。**再起動後に自動で起動する**（nginx などが `systemctl enable` 済み） | Session Manager で接続し、`curl -fsS http://localhost/up` と `systemctl is-enabled nginx` |
| 〃 `curl` | ヘルスチェックの SSM ドキュメントが使う | `command -v curl` |
| 〃 AWS CLI | Basic 認証を使う場合、ヘルスチェックが SSM Parameter Store から認証情報を取り出すのに使う | `command -v aws` |
| Basic 認証のパラメーター（必要な場合） | 「ユーザー名:パスワード」を SSM Parameter Store の SecureString に置く（`aws ssm put-parameter --type SecureString ...`。`--key-id` は指定せず、既定の `aws/ssm` キーで暗号化する）。名前を `health_check.basic_auth_parameter_name` に書く | `aws ssm get-parameter --name <名前> --query Parameter.Type` → `SecureString` |
| セキュリティグループ | 起動テンプレートで使うもの | `aws ec2 describe-security-groups --group-ids <ID>` |
| CodeConnections の接続 | 手順 0 のリポジトリへの接続。**コンソールで承認し、状態が `AVAILABLE` になっていること** | `aws codeconnections get-connection --connection-arn <ARN> --query 'Connection.ConnectionStatus'` |
| デプロイする人の権限 | CloudFormation で IAM ロール・S3・CodePipeline・CodeBuild・SSM ドキュメント・起動テンプレートを作成できる | — |

## 2. 設定値の記入と再生成

`config/ami_publish.yml` のダミーの値を置き換える。

| 項目 | ダミーの値 | 置き換えるもの |
|---|---|---|
| `aws_region` | `ap-northeast-1` | 使うリージョン |
| `release_instance_id` | `i-0123456789abcdef0` | リリース用インスタンスの ID |
| `pipeline.source_connection_arn` | `arn:aws:codeconnections:...:connection/0000...` | 手順 1 の接続の ARN |
| `pipeline.source_repository_id` | `example-org/ami-publish` | 手順 0 のリポジトリ（`オーナー/リポジトリ名`） |
| `pipeline.source_branch_name` | `main` | パイプラインが取得するブランチ |
| `launch_template.security_group_ids` | `sg-0123456789abcdef0` | 手順 1 のセキュリティグループ |
| `launch_template.instance_type` | `t3.small` | 本番で使うインスタンスタイプ |
| `application_name` | `myapp` | アプリケーション名（英小文字・数字・ハイフン）。スタックなどの名前はこれと環境名から自動で決まる |

スタック・パイプライン・ロググループ・SSM ドキュメントなどの名前は書かない。`application_name` と環境名から自動で決まり、仕組みの生成ツールの実行時に一覧が表示される（以降の手順の `myapp-staging-...` は `application_name: myapp`・環境 `staging` の場合の名前）。

置き換えたら、パイプラインの作成の 2・3 段階を行う。

```bash
cd ami-publish                               # 手順 0 のリポジトリのルート
go run ./cmd/generate-definitions
go run ./cmd/generate-definitions --check
go test ./...
cfn-lint generated/cloudformation/*/*.yml
```

`generated/` の差分をレビューし、承認後にリポジトリの、パイプラインが取得するブランチへ反映する（パイプラインは実行時にこのブランチの buildspec・ツール・設定値を使う）。

## 3. 仕組みのデプロイ

仕組みの生成ツールが出力したデプロイ用シェルスクリプトを実行する（スタック名は命名規則どおりに入っている）。3 つのスタックとも変更セットを作るだけで反映はしないので、内容を確認してから、ヘルスチェック → 起動テンプレート → AMI 公開パイプラインの順に反映する（詳細は [README](./ami-publish/README.md#4-仕組みのデプロイaws-cli)）。

```bash
bash generated/deploy/staging.sh up
```

初回は、1 回目の `up` でパイプライン（3 つ目）の変更セットの作成がエラーで止まる（ヘルスチェックと起動テンプレートの Export がまだないため）。ヘルスチェックと起動テンプレートの変更セットを反映してから、もう一度 `up` を実行する。

変更セットを確認する観点:

- ヘルスチェック: `AWS::SSM::Document` 1 つだけ
- 起動テンプレート: `AWS::IAM::Role`、`AWS::IAM::InstanceProfile`、`AWS::EC2::LaunchTemplate` の 3 つだけ
- パイプライン: S3 バケット、ロググループ、IAM ロール 3 つ、CodeBuild プロジェクト、CodePipeline

Basic 認証を使う場合は、ヘルスチェックのスタックのデプロイ後に、出力 `BasicAuthParameterReadPolicyArn` の管理ポリシーを、リリース用インスタンスの IAM ロールにアタッチする。

```bash
aws cloudformation describe-stacks --stack-name myapp-staging-health-check \
  --query "Stacks[0].Outputs[?OutputKey=='BasicAuthParameterReadPolicyArn'].OutputValue" --output text
aws iam attach-role-policy --role-name <リリース用インスタンスのロール名> --policy-arn <上の ARN>
```

## 4. デプロイ結果の確認

| # | 確認 | コマンド | 期待結果 |
|---|---|---|---|
| 4-1 | スタックの状態 | `aws cloudformation describe-stacks --stack-name <各スタック> --query 'Stacks[0].StackStatus'` | 3 つとも `CREATE_COMPLETE` |
| 4-2 | 起動テンプレート | `aws ec2 describe-launch-template-versions --launch-template-name myapp-staging --query 'LaunchTemplateVersions[0].[VersionDescription,LaunchTemplateData.ImageId]'` | `myapp (AMI not set)` と `null`（初回はまだ AMI が入っていない） |
| 4-3 | パイプラインの出力 | `aws cloudformation describe-stacks --stack-name myapp-staging-ami-publish-pipeline --query 'Stacks[0].Outputs'` | `LaunchTemplateStackName`・`HealthCheckDocumentName`・`LogGroupName` などがある |
| 4-4 | 作成直後の自動実行 | `aws codepipeline list-pipeline-executions --pipeline-name myapp-staging-ami-publish` | 作成直後に 1 回実行されていれば `Failed`（`VERSION` 未指定で終了コード 2）。CodeBuild のログに「--version を指定する」。AMI は作られていない |
| 4-5 | CodeBuild の Ruby | 4-4 の CodeBuild のログ | `ruby --version` が 3.4.10、`bundle install` が成功している（`rbenv local 3.4.10` が失敗した場合は、イメージに 3.4.10 がない。`codeBuildRubyVersion` をイメージにあるバージョンに上げる） |
| 4-6 | ヘルスチェックの単体実行 | 下記 | `Success` |
| 4-7 | `plan` | 下記 | 終了コード 0。`ssm_managed`、`release_instance_permissions_checked`（`missing` が空）、`create_image_planned`、`launch_template_stack_update_planned` がログに出る。AWS に変更がない。リリース用インスタンスが SSM の管理対象でなければ、ここで終了コード 1（「SSM の管理対象になっていない」）になる |

4-6 ヘルスチェックの単体実行（SSM ドキュメントがリリース用インスタンスで動くか）:

```bash
COMMAND_ID=$(aws ssm send-command --document-name myapp-staging-health-check \
  --instance-ids <リリース用インスタンス ID> --query Command.CommandId --output text)
aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id <リリース用インスタンス ID> \
  --query '[Status,StandardOutputContent]'
```

4-7 `plan`（手元から。[手元での確認](./ami-publish/README.md#aws-を使う実行)の権限が必要）:

```bash
AWS_PROFILE=<プロファイル名> bundle exec ruby bin/ami_publish plan --environment staging --version v1.0.0
echo "exit=$?"
```

## 5. 初回の AMI 公開

リリース用インスタンスに公開するバージョン（例: `v1.0.0`）が配置・起動済みであることを確認してから実行する。**AMI の作成中にリリース用インスタンスが再起動する。**

```bash
aws codepipeline start-pipeline-execution --name myapp-staging-ami-publish \
  --variables name=VERSION,value=v1.0.0
```

進行状況は、パイプラインの画面、または CodeBuild のログ（CloudWatch Logs `/myapp/staging/ami-publish`、ストリーム `codebuild/...`）で確認する。ログは JSON 形式で、`step_started` / `step_finished` がステップ 1〜6 の順に出る。待っている間は 60 秒ごとに進捗ログ（`"event":"waiting"`）が出る（[進捗ログ](./ami-publish/README.md#進捗ログ)）。進捗ログが出ているのに先へ進まない場合は、その項目（ステップ 3 なら `ping_status` など）で原因を切り分ける。

| # | 確認 | コマンド | 期待結果 |
|---|---|---|---|
| 5-1 | パイプライン | `aws codepipeline get-pipeline-state --name myapp-staging-ami-publish --query 'stageStates[].latestExecution.status'` | `Succeeded` |
| 5-2 | AMI | `aws ec2 describe-images --owners self --filters Name=tag:AppVersion,Values=v1.0.0 --query 'Images[].[ImageId,State,Tags]'` | `available`。タグ `Name`（`<ami.name_tag_prefix>_<バージョン>_<日時>`。接頭辞の省略時は `<バージョン>_<日時>`）/ `App` / `Environment` / `AppVersion` / `Verified=manual` / `PipelineExecutionId` / `Status=published` / `HealthCheck=passed` |
| 5-3 | スナップショットのタグ | `aws ec2 describe-snapshots --owner-ids self --filters Name=tag:AppVersion,Values=v1.0.0 --query 'Snapshots[].Tags'` | AMI と同じタグ（`Status` は `creating` のまま） |
| 5-4 | 起動テンプレート | `aws ec2 describe-launch-template-versions --launch-template-name myapp-staging --query 'LaunchTemplateVersions[0].[VersionNumber,VersionDescription,LaunchTemplateData.ImageId]'` | 新しいバージョン、説明 `myapp v1.0.0`、5-2 の AMI |
| 5-5 | スタックのパラメータ | `aws cloudformation describe-stacks --stack-name myapp-staging-launch-template --query 'Stacks[0].Parameters'` | `AmiId` が 5-2 の AMI、`AppVersion=v1.0.0` |
| 5-6 | 出力変数 | パイプラインの実行詳細で、アクション `PublishAmi` の出力変数 | `AMI_ID`、`LAUNCH_TEMPLATE_VERSION` |
| 5-7 | リリース用インスタンス | `describe-instance-information` の `PingStatus` と `curl http://localhost/up` | 再起動後も `Online`、アプリが応答する |
| 5-8 | ヘルスチェックの出力 | CloudWatch Logs `/myapp/staging/ami-publish` の SSM のストリーム | `health check passed` |
| 5-9 | 所要時間 | CodeBuild のログの `duration_seconds` | 各ステップの時間を記録し、`config/ami_publish.yml` の `timeouts` とビルドのタイムアウト（`timeouts.codebuild_minutes`、60 分）に余裕があるか確認する |

## 6. 障害試験

開発計画の M6 に対応する。各試験の後、リリース用インスタンスを元の状態に戻す。

### 6-1. ヘルスチェックの失敗（AMI の削除）

1. リリース用インスタンスで、アプリが再起動後に起動しないようにする（例: `sudo systemctl disable nginx`。**起動中のものは止めない**）。
2. パイプラインを実行する（`VERSION=v1.0.1` など）。
3. 期待結果:
   - パイプラインが失敗し、ログに `image_deleted`（理由: 再起動後のヘルスチェックが失敗した）が出る
   - 作られた AMI が登録解除され、スナップショットも削除されている（`describe-images` で `v1.0.1` が見つからない）
   - 起動テンプレートは 5-4 のまま（新しいバージョンができていない）
4. 元に戻す: `sudo systemctl enable --now nginx`。

### 6-2. 再実行（作成済み AMI の再利用）

1. パイプラインを実行し、ログに `image_creation_started` が出た後（ステップ 2 の待機中）に、CodeBuild のビルドを停止する。
2. パイプラインの画面で、失敗したアクション `PublishAmi` を**再試行（Retry）**する（同じ実行 ID のまま再実行される）。
3. 期待結果: ログに `image_reused` が出て、新しい AMI を作らずに続きから完走する。

### 6-3. 同時実行

1. パイプラインを続けて 2 回実行する（`VERSION` を変える）。
2. 期待結果: 2 回目は 1 回目の完了を待ってから実行される（実行モード `QUEUED`）。AMI の作成が重ならない。

### 6-4. ロールバック

5 の後にもう 1 回公開してから（例: `v1.0.2`）、手元で実行する。

```bash
AWS_PROFILE=<プロファイル名> bundle exec ruby bin/ami_publish rollback --environment staging --to-version v1.0.0 --dry-run
AWS_PROFILE=<プロファイル名> bundle exec ruby bin/ami_publish rollback --environment staging --to-version v1.0.0
```

期待結果:

- `--dry-run`: ログの `change_set_changes` が `Modify AWS::EC2::LaunchTemplate LaunchTemplate` だけ。起動テンプレートは変わらない
- 実行: 起動テンプレートに新しいバージョンができ、`ImageId` が `v1.0.0` の AMI になる。AMI のタグは変わらない
- 存在しないバージョン（例: `v9.9.9`）を指定すると、終了コード 1 で何も変更しない

### 6-5. 想定外の差分での中止（任意）

AMI 公開ツールはテンプレート本体を変えないため、通常は起動テンプレート以外の差分は出ない。この安全装置は単体テストで確認済みのため、稼働環境での確認は任意とする。行う場合は、起動テンプレートのスタックに、`AppVersion` をインスタンスロールのタグに使うなど「パラメータの変更で起動テンプレート以外のリソースも変わる」テンプレートを一時的にデプロイしてからパイプラインを実行し、変更セットが削除されて中止されること（ログに「起動テンプレート以外の変更が含まれているため中止した」）を確認する。確認後、元のテンプレートに戻す。

### 6-6. 権限の確認（任意）

CodeBuild のサービスロールから権限を 1 つずつ外して実行し、該当するステップで AWS のエラー（終了コード 3）として止まることを確認する。IAM の変更が必要なため、行うかどうかは運用方針で決める。

### 6-7. 停止中のリリース用インスタンスからの公開

1. リリース用インスタンスを停止する（`aws ec2 stop-instances --instance-ids <ID>`、`stopped` になるまで待つ）。
2. パイプラインを実行する。
3. 期待結果:
   - ログに `instance_state_checked`（状態 `stopped`）が出る
   - AMI の作成時にインスタンスは起動しない（停止したまま AMI が作られる）
   - AMI が available になった後、`instance_started` が出てインスタンスが起動し、SSM の接続とヘルスチェックを経て、起動テンプレートが更新される
   - パイプラインの終了後も、インスタンスは起動したまま（停止に戻す場合はパイプラインの外で行う）
4. リリース用インスタンスの EBS をカスタマー管理の KMS キーで暗号化している場合、起動に KMS の権限が必要になることがある。起動に失敗したら、CodeBuild のロールと KMS キーのポリシーを確認する。

### 6-8. ヘルスチェックの省略

1. パイプラインを `--variables name=VERSION,value=v1.0.3 name=HEALTH_CHECK,value=false` で実行する。
2. 期待結果:
   - ログに `ssm_check_skipped`、`release_instance_permissions_check_skipped`、`start_instance_skipped`、`wait_instance_online_skipped`、`health_check_skipped` が出る
   - 起動テンプレートの新しいバージョンができ、AMI にタグ `HealthCheck=skipped` が付く
   - 開始時に停止中だった場合は、インスタンスは停止したまま

## 7. 後片付けと記録

### 試験で作った AMI の削除

このパイプラインは AMI の保持数を管理しない（決定事項 D8）。試験で作った AMI とスナップショットは手で削除する。**起動テンプレートの現在のバージョンが参照している AMI は削除しない。**

```bash
# 対象の確認
aws ec2 describe-images --owners self --filters Name=tag:App,Values=myapp Name=tag:Environment,Values=staging \
  --query 'Images[].[ImageId,Name,Tags[?Key==`AppVersion`]|[0].Value,Tags[?Key==`Status`]|[0].Value]' --output table

# 削除（AMI ごと）
aws ec2 describe-images --image-ids <AMI> --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text
aws ec2 deregister-image --image-id <AMI>
aws ec2 delete-snapshot --snapshot-id <上で表示されたスナップショット>
```

### 環境ごと撤去する場合

デプロイ用シェルスクリプトの `down`（`bash generated/deploy/staging.sh down`）で、パイプライン → 起動テンプレート → ヘルスチェックの順にスタックを削除する（パイプラインのスタックの S3 バケットも、先に空にしてから削除する）。

### 記録

| 項目 | 結果 | 日付・担当 | メモ |
|---|---|---|---|
| 4 デプロイ結果の確認 | | | |
| 5 初回の AMI 公開 | | | 所要時間: |
| 6-1 ヘルスチェックの失敗 | | | |
| 6-2 再実行 | | | |
| 6-3 同時実行 | | | |
| 6-4 ロールバック | | | |
| 6-5 想定外の差分（任意） | | | |
| 6-6 権限（任意） | | | |
| 6-7 停止中からの公開 | | | |
| 6-8 ヘルスチェックの省略 | | | |

所要時間の実測値をもとに、`config/ami_publish.yml` の `timeouts` と CodeBuild のタイムアウトを見直す（開発計画のリスク「SSM Agent の再接続が遅い」「AMI 作成の長時間化」）。
