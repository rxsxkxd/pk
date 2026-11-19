# CloudFormation YAML のパイプライン用スタック

このフォルダの親（`ip-port-guard-rule-refresh-pipeline/`）で実行する。スタックは[パイプライン用](list-refresh-pipeline.yml)の 1 種類だけで、環境ごとに作る。ここにあるコマンドは手順であり、実際の AWS への作成は未実施。

| バケット | このスタックでの扱い |
|---|---|
| パイプラインの受け渡しバケット | **このスタックが作る**。`port-guard-handoff-<環境>-<アカウント ID>-<リージョン>-an`（名前は全体で 63 文字までなので、先頭部分を短くしている）。アカウントのリージョナル名前空間・バージョニング有効・SSE-S3 暗号化・パブリックアクセス全ブロック・ACL 無効。古いバージョンは90日で削除する。スタックを削除・置き換えしてもバケットは残す |
| ルールのデプロイ先バケット | **作らない**。先に手で作ったもの（ローカル・踏み台サーバーからも使う）を、`RuleDeployBucketNamePrefix` で名前の先頭部分（既定 `ip-port-guard-rules`）を受け取り、`<先頭部分>-<アカウント ID>-<リージョン>-an` を参照する。設定は変更しない |

バケットの呼び方は[プロジェクトの README の用語](../README.md#用語)。

## ルールのデプロイ先バケットの作り方（記録）

ルールのデプロイ先バケットの定義は [rule-deploy-bucket.yml](rule-deploy-bucket.yml) に残している。このアカウントでは 2026-11-17 に手で作成済みなので、**流さない**。別のアカウント・リージョンで作るとき、または作り直すときに使う。アカウントのリージョナル名前空間・バージョニング有効（古い版は消さない）・SSE-S3 暗号化・パブリックアクセス全ブロック・ACL 無効で、スタックを削除してもバケットは残す。

```bash
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" cloudformation deploy \
  --stack-name port-guard-rule-deploy-bucket \
  --template-file cloudformation/rule-deploy-bucket.yml
```

名前の先頭部分 `RuleDeployBucketNamePrefix`（既定 `ip-port-guard-rules`）は、パイプライン用スタックの同じ名前のパラメータと合わせる。手で作ったバケットの設定（バージョニング・暗号化）がこの定義と同じかは、確かめていない。

## 1. 前提

ルールジェネレーターのリポジトリを、`SourceProvider` で GitHub か CodeCommit から選ぶ（違いは[プロジェクトの README](../README.md#codepipeline-で実行する)）。

- GitHub: CodeConnections でリポジトリへの接続を作り、認可を完了させた `AVAILABLE` の接続 ARN を使う。CodeConnections を使えるリージョンを選ぶ（大阪リージョンでは使えない。この手順は東京リージョンを例にしている）
- CodeCommit: パイプラインと同じアカウント・リージョンにあるリポジトリの名前を使う。接続は要らない

リポジトリ・ルールのデプロイ先バケット・パイプラインは同じアカウント・リージョンで使う。

## 2. パイプライン用スタックを作る

```bash
export AWS_REGION=ap-northeast-1
export AWS_PROFILE=your-profile

SOURCE_DIRECTORY=docs/ec2-port-guard-rollout/ip-port-guard-rule-refresh-pipeline

# ルールジェネレーターのリポジトリが GitHub のとき（実際の接続・リポジトリに置き換える）
SOURCE_PARAMETERS=(SourceProvider=GitHub
  ConnectionArn=arn:aws:codeconnections:ap-northeast-1:111122223333:connection/your-connection-id
  FullRepositoryId=your-owner/your-repository)
# ルールジェネレーターのリポジトリが CodeCommit のときは、上の代わりにこちら
# SOURCE_PARAMETERS=(SourceProvider=CodeCommit CodeCommitRepositoryName=your-repository)

aws --region "$AWS_REGION" --profile "$AWS_PROFILE" cloudformation deploy \
  --stack-name port-guard-list-refresh-staging \
  --template-file cloudformation/list-refresh-pipeline.yml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    EnvironmentName=staging \
    "${SOURCE_PARAMETERS[@]}" \
    BranchName=main SourceDirectory="$SOURCE_DIRECTORY"
```

このプロジェクトをリポジトリ直下に置いているなら `SOURCE_DIRECTORY=.` にする。`allow-lists/<環境>/` は同じソースから読み込む。独自の ZIP 作成やスクリプトの S3 への事前配置は不要。

| パラメータ | 既定値・指定するもの |
|---|---|
| `EnvironmentName` | 必須。`development`・`staging`・`production` |
| `RuleDeployBucketNamePrefix` | `ip-port-guard-rules`。手で作ったルールのデプロイ先バケットの名前の先頭部分（アカウントのリージョナル名前空間で作ってある前提） |
| `SourceProvider` | `GitHub`。ルールジェネレーターのリポジトリのホスト。`GitHub` か `CodeCommit` |
| `ConnectionArn` | `GitHub` のとき必須。認可済み CodeConnections 接続 ARN。`CodeCommit` のときは空 |
| `FullRepositoryId` | `GitHub` のとき必須。大文字・小文字も含めた `owner/repository`。`CodeCommit` のときは空 |
| `CodeCommitRepositoryName` | `CodeCommit` のとき必須。リポジトリの名前。`GitHub` のときは空 |
| `BranchName` | `main`。両方で使う |
| `SourceDirectory` | `.`。リポジトリ直下を基準としたプロジェクトの場所 |
| `ScheduleExpression` | `cron(0 0 ? * MON,THU *)`（毎週月曜・木曜の UTC 0:00 ＝ 日本時間 9:00）。定期実行の予定（EventBridge Scheduler の式。UTC で書く）。空なら定期実行しない。定期実行は承認を飛ばす |
| `NotificationTopicArn` | 空。Make のビルドが失敗したとき（増減の確認で止まったときを含む）に、止まった理由と増減を送る既存の SNS のトピックの ARN。空なら送らない。KMS で暗号化されたトピックは、今は使えない（ロールにキーの権限がない） |
| `LogRetentionInDays` | `90` |

ルールのデプロイ先バケットには SSE-S3 を想定している。SSE-KMS のバケットを使う場合は、使用するキーへの権限とキーポリシーの追加が別途必要になる。

## 3. 開始と承認

**スタックを作った直後に、パイプラインが自動で 1 回動く**（CodePipeline は作られたときに必ず 1 回動き、止める設定はない。[パイプラインの開始](https://docs.aws.amazon.com/codepipeline/latest/userguide/pipelines-about-starting.html)、2026-11-18 に確かめた）。この 1 回は変数 `APPROVAL` が既定値の `required` なので、Check のステージで止まる。**この 1 回目は却下する**。

承認を挟むかは、開始するときの変数 `APPROVAL` で決まる。Web コンソールから人が開始すると既定値の `required` のままで承認で止まり、定期実行とコマンドからの開始では `skip` を渡して Check を飛ばす（Check のステージの入り口の条件。`VariableCheck` の規則で `#{variables.APPROVAL}` が `required` と等しくなければ、結果 Skip でステージを飛ばす）。

```bash
# コマンドから開始する（承認を飛ばす。付け忘れると承認で止まる）
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" codepipeline start-pipeline-execution \
  --name port-guard-list-refresh-staging --variables name=APPROVAL,value=skip

# 増減を確認したうえで 5% の判定を通すとき
aws --region "$AWS_REGION" --profile "$AWS_PROFILE" codepipeline start-pipeline-execution \
  --name port-guard-list-refresh-staging --variables name=FORCE,value=1 name=APPROVAL,value=skip
```

Web コンソールから開始した回は、ビルドログの件数・増減を確認し、CodePipeline のコンソールから承認する。後段は、承認したビルドの成果物（パイプラインの受け渡しバケットにある）に含まれる `deploy-rules.sh` と `work/<環境>/` を使う。Make のビルドは、渡すファイルを決まった名前のフォルダ `handoff/` に写してから成果物にする（buildspec の `base-directory` で環境変数が展開されるとはドキュメントに書かれていないため、`SourceDirectory` の値に頼らない）。ルールジェネレーターのリポジトリの最新内容を取り直して作り直すことはしない。

ソース変更による自動開始は無効（作成直後の 1 回は上のとおり）。`QUEUED` はこのパイプライン内の実行を直列にするが、ローカルでの実行とは排他しない。

## 検証

```bash
cfn-lint cloudformation/list-refresh-pipeline.yml cloudformation/rule-deploy-bucket.yml
```

CDK と共通の動作・権限・模擬実行テストは [CDK の README](../cdk/python/README.md) を参照する。

仕様を確認した公式資料（2026-11-17）: [S3 バケットの CloudFormation 定義](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-s3-bucket.html)、[CodeConnections の設定と必要な権限](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodestarConnectionSource.html)、[CodeCommit のソースアクションと必要な権限](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodeCommit.html)（2026-11-18）、[パイプラインの成果物用権限](https://docs.aws.amazon.com/codepipeline/latest/userguide/how-to-custom-role.html)、[CodeBuild の buildspec と成果物](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)、[S3 の名前空間と名前の長さ](https://docs.aws.amazon.com/AmazonS3/latest/userguide/gpbucketnamespaces.html)（2026-11-18）。
