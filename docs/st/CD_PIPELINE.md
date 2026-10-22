# CD パイプライン（CodePipeline / CodeBuild）

master への push で、**単体テスト → E2E → Lambda のコードと SPA のファイルだけのデプロイ** を流すパイプライン。AWS の CodePipeline（V2）と CodeBuild で動かす。

> **状態（2026-10-22）**: テンプレートと手順を作り、手元で確かめられる範囲だけ確かめた（9章）。AWS 上ではまだ作っていない。E2E の段は、何もしない空のビルドを置いてある（6章）。

関連: デプロイを「更新だけ」にする考え方は [CD_UPDATE_ONLY.md](CD_UPDATE_ONLY.md)（このパイプラインはその案を採ったもの）。CodePipeline の構成パターンの比較は [CD_CI.md](CD_CI.md) 0章。GitHub Actions の CI（pull request ごとのテスト）は [CI.md](CI.md)。

## 1. 全体像

```
GitHub（このリポジトリ。master への push）
  └─ CodeConnections（GitHub との接続。AWS 側で管理）
       └─ CodePipeline V2: ticketqr-st（実行は順番待ち QUEUED。デプロイが重ならない）
            ├─ Source  そのコミットのソース
            ├─ Test    CodeBuild ticketqr-st-test    単体テスト（Go・SPA）→ Lambda の zip と SPA の dist を作る
            ├─ E2E     CodeBuild ticketqr-st-e2e     今は何もしない（6章）
            └─ Deploy  CodeBuild ticketqr-st-deploy  zip と SPA のファイルを差し替える（4章）
```

| 方針 | 内容 |
|---|---|
| ビルドは 1 回だけ | Test の段で作った zip と `dist` を、E2E・Deploy の段にそのまま渡す。Deploy の段ではビルドしない |
| デプロイは更新だけ | 差し替えるのは Lambda のコードと SPA のファイルだけ。CloudFormation のスタック、`config.json`、Parameter Store、IAM には触れない（構築は手順書で行う。CD_UPDATE_ONLY.md 1・2章） |
| 権限を分ける | Test・E2E の CodeBuild は AWS の資源に触れない（ログとパイプラインの成果物だけ）。デプロイの権限は Deploy の CodeBuild だけが持ち、その中身も差し替えに要るものだけ（8章） |
| GitHub に AWS の権限を置かない | パイプラインは AWS 側から GitHub を読む（CodeConnections）。GitHub Actions には AWS の権限も秘密情報も渡さない |
| 実装は Go だけ | Node.js 版はパイプラインに入れない |

## 2. ファイル

| ファイル | 内容 |
|---|---|
| `infra/cloudformation/pipeline.yaml` | パイプライン、CodeBuild のプロジェクト 3 つ、ロール 3 つ、段の間の受け渡し用のバケット、ログ |
| `cd/buildspec/test.yml` | Test の段（3章） |
| `cd/buildspec/e2e.yml` | E2E の段（何もしない。6章） |
| `cd/buildspec/deploy.yml` | Deploy の段。`cd/deploy.sh` を呼ぶだけ |
| `cd/deploy.sh` | 差し替えの本体（4章）。手元でも同じものを流せる |

buildspec はリポジトリの中にあるので、手順はコミットごとに固定される（パイプラインの設定を変えなくても、buildspec を直して push すれば次の実行から変わる）。

## 3. Test の段（単体テストとビルド）

| 順 | コマンド | 内容 |
|---|---|---|
| 1 | `npm --prefix web ci` | SPA の依存を入れる |
| 2 | `make -C go test` | `go vet` と Go の単体テスト |
| 3 | `make -C go build` | Lambda 用の zip（arm64）。使うのは `go/bin/ticketqr.zip` |
| 4 | `npm --prefix web run format:check` | Prettier |
| 5 | `npm --prefix web test` | Vitest |
| 6 | `npm --prefix web run build` | 型チェックと SPA のビルド。発行方式は CodeBuild の環境変数 `GRANT_MODE`（`pipeline.yaml` の `GrantMode`。既定 `page`） |

- 単体テストは外に通信しない。画像解析サーバーは偽物（Go の `stubVerifier`）か、テストの中で立てるローカルのサーバー（`httptest`）、SPA の `fetch` は `vi.stubGlobal` で差し替えている。外への通信を止めた状態で全件通ることを確かめた（2026-10-22。macOS の `sandbox-exec`）
- 外に出るのは、依存の取得（`npm ci`、Go のモジュール）と、次の Go 本体の取得だけ
- 環境: CodeBuild の ARM のイメージ `aws/codebuild/amazonlinux-aarch64-standard:4.0`。Node.js は 24、Go は 1.26 まで入っている。`go.mod` の `go` 行（今は 1.27.3）がそれより新しいので、`GOTOOLCHAIN=auto` で go コマンドに Go 本体を取らせる（チェックサムで検証される）。イメージに `go.mod` の版が入ったら、`runtime-versions` を上げて `GOTOOLCHAIN` を外せる（[MAINTENANCE.md](MAINTENANCE.md)）
- 次の段に渡すもの: `go/bin/ticketqr.zip`、`web/dist/`、`cd/`（Deploy の段のスクリプト）

## 4. Deploy の段（差し替えだけ）

`cd/deploy.sh` が次の順に行う。

| 順 | やること | コマンド |
|---|---|---|
| 1 | zip を控えの場所と、スタックが指す場所に置く | `aws s3 cp` → `s3://<成果物バケット>/ticketqr/go/releases/<コミット>/ticketqr.zip` と `…/current/ticketqr.zip` |
| 2 | 2 つの関数のコードを差し替え、反映を待つ | `aws lambda update-function-code`（`current` の zip）、`aws lambda wait function-updated` |
| 3 | SPA の控えを置く（ロールバック用） | `aws s3 sync web/dist/ s3://<成果物バケット>/ticketqr/go/web-releases/<コミット>/`（`config.json` を除く） |
| 4 | SPA の `assets/*` を上げ、古いものを消す | `aws s3 sync … --delete`（`index.html` と `config.json` を除く。1 年キャッシュ） |
| 5 | `index.html` を最後に上げる | `aws s3 cp`（`no-cache`）。古い `index.html` が、まだない `assets/*` を指すことがない順番 |
| 6 | CloudFront のキャッシュを消す | `aws cloudfront create-invalidation --paths /index.html` |
| 7 | スモークテスト（`WEB_URL` を入れたときだけ） | 画面と `config.json` が 200 で返ること |

- `config.json`（環境ごとの設定）は上げない・消さない。Web のスタックを作ったときに置いたものを使い続ける（web/DEPLOY.md 6章）
- スモークテストでは発行しない（解析サーバーを呼ばない）。発行まで確かめるのは aws-test/PLAN.md の A
- API のスタックの `ArtifactPrefix` は `ticketqr/go/current` にしておく（5.2 の 3）。こうすると、あとで構築の手順でスタックを更新しても、今動いているコードのまま変わらない（CD_UPDATE_ONLY.md 3.1）
- SAM（infra/sam）で作った環境でも使える（関数名を `pipeline.yaml` のパラメータで渡す）。ただし、その後に `sam deploy` をすると、SAM がビルドしたコードに置き換わる

## 5. 構築の手順（初回だけ）

作業ディレクトリで、AWS CLI に構築用の権限がある状態で行う。リージョンは API・Web のスタックと同じにする。

### 5.1 前提

| 前提 | 内容 |
|---|---|
| リポジトリ | このディレクトリを GitHub の専用のリポジトリにしてある（ルートに `cd/`・`go/`・`web/` がある） |
| 成果物バケット | DEPLOY.md 2章 |
| API のスタック | go/DEPLOY.md 4-A.1 で作ってある（`ticketqr-go`） |
| Web のスタック | web/DEPLOY.md 3章で作り、`config.json` を置いてある（6章） |

### 5.2 手順

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

3. **API のスタックが `current` の zip を指すようにする**（CD_UPDATE_ONLY.md 3.1）

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
     --template-file infra/cloudformation/pipeline.yaml --capabilities CAPABILITY_NAMED_IAM \
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

### 5.3 パラメータ（`pipeline.yaml`）

| パラメータ | 既定 | 内容 |
|---|---|---|
| `NamePrefix` | `ticketqr-st` | パイプライン・CodeBuild・ロールの名前の先頭 |
| `ConnectionArn` | - | 5.2 の 1 |
| `FullRepositoryId` | - | `owner/name` |
| `BranchName` | `master` | このブランチへの push で動く |
| `ArtifactBucket` | - | 成果物バケット |
| `ArtifactPrefix` | `ticketqr/go` | 成果物バケットの中の置き場所（`current/`・`releases/`・`web-releases/` をこの下に作る） |
| `TicketsFunctionName` / `GetQRFunctionName` | `ticketqr-go-tickets` / `ticketqr-go-get-qr` | 差し替える関数（`api.yaml` の名前）。SAM の環境では `<NamePrefix>-tickets` など |
| `WebBucketName` / `DistributionId` / `WebUrl` | - / - / 空 | Web のスタックの出力。`WebUrl` が空ならスモークテストを飛ばす |
| `GrantMode` | `page` | SPA の発行方式 |
| `LogRetentionDays` | 30 | CodeBuild のログを残す日数 |

## 6. E2E の段（今は空）

`cd/buildspec/e2e.yml` は、メッセージを出して成功するだけ。段の場所と CodeBuild のプロジェクトは先に作っておき、中身はあとで入れる。

入れるときの候補と注意:

| 項目 | 内容 |
|---|---|
| A: 今の compose の E2E を CodeBuild で流す | CodeBuild のプロジェクトを特権モード（`PrivilegedMode: true`）にして、`docker compose -f compose.e2e.yaml up --build ...` を流す（E2E_RUN.md 2章）。Test の段の `web/dist` を使えるが、compose は API をソースから作り直す（E2E.md 2.3）ので、入力にはソースも要る（`pipeline.yaml` の E2E の段の入力に `SourceOutput` を足す） |
| A の注意 | 毎回、golang・node・Playwright・Garage のイメージを取得する（合わせて数 GB）。Docker Hub は取得の回数に上限があり、CodeBuild の共有の IP では上限に当たりやすい。ECR Public のミラー（`public.ecr.aws/docker/library/golang` など）に替えるか、ECR のプルスルーキャッシュを使う |
| B: デプロイしたあとに、本物の環境に対して流す | Deploy の段のあとに段を足し、Playwright のテストを本物の CloudFront・API Gateway に対して流す（CD_CI.md 0.5 の E2） |

## 7. ロールバック

前の版の控えを使う。ビルドし直さなくてよい。

```sh
SHA=<戻したいコミット>
P=ticketqr/go
# Lambda
aws s3 cp "s3://$ARTIFACT_BUCKET/$P/releases/$SHA/ticketqr.zip" "s3://$ARTIFACT_BUCKET/$P/current/ticketqr.zip"
for fn in ticketqr-go-tickets ticketqr-go-get-qr; do
  aws lambda update-function-code --function-name "$fn" --s3-bucket "$ARTIFACT_BUCKET" --s3-key "$P/current/ticketqr.zip"
  aws lambda wait function-updated --function-name "$fn"
done
# SPA
aws s3 sync "s3://$ARTIFACT_BUCKET/$P/web-releases/$SHA/" "s3://$WEB_BUCKET/" --delete \
  --exclude index.html --exclude config.json --cache-control 'public, max-age=31536000, immutable'
aws s3 cp "s3://$ARTIFACT_BUCKET/$P/web-releases/$SHA/index.html" "s3://$WEB_BUCKET/index.html" \
  --cache-control no-cache --content-type 'text/html; charset=utf-8'
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths /index.html
```

戻したあとの master への push で、パイプラインはまた最新のコミットを出す。直すまで出したくないときは、パイプラインの段の移行を止める（`aws codepipeline disable-stage-transition --pipeline-name ticketqr-st --stage-name Deploy --transition-type Inbound --reason ...`）。

## 8. 権限

| ロール | 使うもの | 権限 |
|---|---|---|
| `ticketqr-st-pipeline` | CodePipeline | GitHub との接続の利用、3 つの CodeBuild の開始、段の間の受け渡し用のバケット |
| `ticketqr-st-build` | Test・E2E の CodeBuild | ログと、受け渡し用のバケットの読み書きだけ（AWS の資源には触れない） |
| `ticketqr-st-deploy` | Deploy の CodeBuild | 成果物バケットの `ticketqr/go/*` の読み書き、2 つの関数の `UpdateFunctionCode`・`GetFunctionConfiguration`、Web のバケットの書き込み・削除・一覧、そのディストリビューションの `CreateInvalidation`（CD_UPDATE_ONLY.md 4.1 と同じ） |

CloudFormation・IAM・API Gateway・CloudFront の設定を変える権限は、どのロールにもない。長期のアクセスキーもどこにも置かない。

## 9. 確かめたこと（2026-10-22。手元だけ）

| 順 | 確かめたこと | 結果 |
|---|---|---|
| 1 | `pipeline.yaml` の cfn-lint（SAM CLI に入っている 1.53.3） | エラーなし |
| 2 | buildspec 3 つが YAML として読めること | 読めた |
| 3 | `cd/deploy.sh` の shellcheck | 指摘なし |
| 4 | `cd/deploy.sh` を、`aws` と `curl` を記録するだけの偽物に差し替えて流す | 4章の順にコマンドが出た。設定が足りないとき・zip がないときは、何もせずに止まった |
| 5 | Test の段のコマンド（`npm ci` を除く）を手元で流す | Go のテスト・zip、Prettier、Vitest（115 件）、SPA のビルドがすべて成功 |
| 6 | 単体テストが外に通信しないこと | 外への通信を止めて、Go と SPA のテストが全件成功（3章） |

確かめていないこと（[OPEN_ITEMS.md](OPEN_ITEMS.md) 1章）: AWS 上でのスタックの作成と実行、CodeBuild の上で `GOTOOLCHAIN=auto` が Go 1.27.3 を取れること、CodeConnections の接続、Deploy の段の権限が足りること。
