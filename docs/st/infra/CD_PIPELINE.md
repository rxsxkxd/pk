# CD パイプラインの構築（初回だけ）

CD のパイプライン（CodePipeline / CodeBuild）を AWS 上に作る手順。パイプラインが何をするか（段の中身、デプロイ、ロールバック）は [../cd/README.md](../cd/README.md)。

> **状態（2026-10-23）**: AWS 上ではまだ作っていない。テンプレートは cfn-lint だけ確かめた（../cd/README.md 9章）。

| 対象 | 置き場所 |
|---|---|
| テンプレート | `cd/pipeline.yaml`（スタック `ticketqr-st-pipeline`） |
| パイプラインが使う buildspec とスクリプト | `cd/buildspec/`、`cd/deploy.sh` |


作業ディレクトリで、AWS CLI に構築用の権限がある状態で行う。リージョンは API・Web のスタックと同じにする。

## 1. 前提

| 前提 | 内容 |
|---|---|
| リポジトリ | このディレクトリを GitHub の専用のリポジトリにしてある（ルートに `cd/`・`go/`・`web/` がある） |
| 成果物バケット | DEPLOY.md 2章 |
| API のスタック | go/DEPLOY.md 4-A.1 で作ってある（`ticketqr-go`） |
| Web のスタック | web/DEPLOY.md 3章で作り、`config.json` を置いてある（6章） |

## 2. 手順

1. **GitHub との接続を作る**（アカウントに 1 つ）

   ```sh
   aws codeconnections create-connection --provider-type GitHub --connection-name ticketqr-st \
     --query ConnectionArn --output text
   ```

   作った直後は「保留中」。AWS のコンソール（デベロッパー用ツール → 設定 → 接続）でその接続を開き、「保留中の接続を更新」から GitHub App をインストールして、このリポジトリだけを許可する。状態が「利用可能」になれば完了。

2. **値を集める**

   ```sh
   ARTIFACT_BUCKET=<成果物バケット>
   CONNECTION_ARN=<1 の ARN>
   REPO=<owner>/<リポジトリ名>
   out() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }
   WEB_BUCKET=$(out ticketqr-web-go BucketName)
   DIST_ID=$(out ticketqr-web-go DistributionId)
   WEB_URL=$(out ticketqr-web-go WebUrl)
   ```

3. **API のスタックが `current` の zip を指すようにする**（cd/UPDATE_ONLY.md 3.1）

   ```sh
   make -C go build
   aws s3 cp go/bin/ticketqr.zip "s3://$ARTIFACT_BUCKET/ticketqr/go/current/ticketqr.zip"
   aws cloudformation deploy --stack-name ticketqr-go --template-file infra/cloudformation/api.yaml \
     --capabilities CAPABILITY_IAM --parameter-overrides ArtifactPrefix=ticketqr/go/current
   ```

   `--parameter-overrides` に書かないパラメータは、今の値のまま変わらない。

4. **パイプラインのスタックを作る**

   ```sh
   aws cloudformation deploy --stack-name ticketqr-st-pipeline \
     --template-file cd/pipeline.yaml --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides ConnectionArn="$CONNECTION_ARN" FullRepositoryId="$REPO" BranchName=master \
       ArtifactBucket="$ARTIFACT_BUCKET" WebBucketName="$WEB_BUCKET" DistributionId="$DIST_ID" WebUrl="$WEB_URL"
   ```

   作った直後に、パイプラインは今の master で 1 回流れる。

5. **確かめる**

   ```sh
   aws codepipeline get-pipeline-state --name ticketqr-st \
     --query 'stageStates[].[stageName,latestExecution.status]' --output table
   ```

   4 つの段がすべて `Succeeded` になれば成功。Deploy の段のログ（`/aws/codebuild/ticketqr-st-deploy`）の最後に `deployed <コミット>` が出る。

## 3. パラメータ（`pipeline.yaml`）

| パラメータ | 既定 | 内容 |
|---|---|---|
| `NamePrefix` | `ticketqr-st` | パイプライン・CodeBuild・ロールの名前の先頭 |
| `ConnectionArn` | - | 2章の 1 |
| `FullRepositoryId` | - | `owner/name` |
| `BranchName` | `master` | このブランチへの push で動く |
| `ArtifactBucket` | - | 成果物バケット |
| `ArtifactPrefix` | `ticketqr/go` | 成果物バケットの中の置き場所（`current/`・`releases/`・`web-releases/` をこの下に作る） |
| `TicketsFunctionName` / `GetQRFunctionName` | `ticketqr-go-tickets` / `ticketqr-go-get-qr` | 差し替える関数（`api.yaml` の名前）。SAM の環境では `<NamePrefix>-tickets` など |
| `WebBucketName` / `DistributionId` / `WebUrl` | - / - / 空 | Web のスタックの出力。`WebUrl` が空ならスモークテストを飛ばす |
| `GrantMode` | `page` | SPA の発行方式 |
| `LogRetentionDays` | 30 | CodeBuild のログを残す日数 |

## 4. ロール（テンプレートが作るもの）

| ロール | 使うもの | 権限 |
|---|---|---|
| `ticketqr-st-pipeline` | CodePipeline | GitHub との接続の利用、3 つの CodeBuild の開始、段の間の受け渡し用のバケット |
| `ticketqr-st-build` | Test・E2E の CodeBuild | ログと、受け渡し用のバケットの読み書きだけ（AWS の資源には触れない） |
| `ticketqr-st-deploy` | Deploy の CodeBuild | 成果物バケットの `ticketqr/go/*` の読み書き、2 つの関数の `UpdateFunctionCode`・`GetFunctionConfiguration`、Web のバケットの書き込み・削除・一覧、そのディストリビューションの `CreateInvalidation`（cd/UPDATE_ONLY.md 4.1 と同じ） |

CloudFormation・IAM・API Gateway・CloudFront の設定を変える権限は、どのロールにもない。長期のアクセスキーもどこにも置かない。

