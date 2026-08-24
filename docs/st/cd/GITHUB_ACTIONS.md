# GitHub Actions からのデプロイ（旧案。採用していない）

> **状態（2026-10-23）**: CD は CodePipeline / CodeBuild で行うことにした（[README.md](README.md)）。この文書と `github-actions/deploy.yml` は、それ以前の案の記録として残している（元は CI.md 4章と `github-template/workflows/deploy.yml`）。
>
> **このままでは動かない**: `deploy.yml` は、最初に CI のワークフロー（`./.github/workflows/ci.yml`）を `workflow_call` で呼び、その成果物（`lambda-go`・`web-dist-*`）を使う作りだった。今の CI（[../ci/README.md](../ci/README.md)）は単体テストだけで、`workflow_call` も成果物もない。使うなら、ビルドと成果物の受け渡しを `deploy.yml` の側に足す必要がある。

デプロイのたびに、CloudFormation のスタックの作成・更新と、ファイルの更新をまとめて行う形。構築と更新を分ける考え方は [UPDATE_ONLY.md](UPDATE_ONLY.md)。

## 1. 流れ

手動で実行し、**実装**（`go`）、**構成**（`layout`。`direct` = 直結、`unified` = 統合。web/DEPLOY.md の冒頭）と **環境**（GitHub の environment。例: `dev`、`prod`）を選ぶ。画像の上限は、environment の変数 `MAX_IMAGE_BYTES`（任意。既定 4194304）で API と `config.json` の両方に入る。

| ステップ | 内容 | 手順書 |
|---|---|---|
| CI | `ci.yml` を呼ぶ（当時の CI。ビルド・単体テスト・E2E）。E2E まで通らなければ、ここで止まる | - |
| 承認 | environment に承認者を設定していれば、ここで承認を待つ | - |
| AWS の認証 | OIDC で `AWS_DEPLOY_ROLE_ARN` のロールを引き受ける | - |
| zip のアップロード | `s3://$ARTIFACT_BUCKET/ticketqr/{impl}/{sha}-{試行回数}/` に置く（接頭辞を毎回変えるので、Lambda のコードが必ず更新される） | {impl}/DEPLOY.md 4-A.1（zip のアップロード） |
| API のスタック | `api.yaml` を `ticketqr-{impl}` にデプロイし、`ApiUrl`・`ApiDomain` を取り出す。統合で、Web のスタックがすでに統合になっていれば、`PublicBaseUrl` にその CloudFront の URL を渡す | {impl}/DEPLOY.md 4-A.1（スタックのデプロイ） |
| Web のスタック | `web.yaml` を `ticketqr-web-{impl}` にデプロイし（直結は `ApiBaseUrl`、統合は `ApiOriginDomain` を渡す）、バケット・ディストリビューション・URL を取り出す | web/DEPLOY.md 3.1・3.2 |
| API の公開 URL（統合だけ） | 初回（または直結からの切り替え）だけ、API を `PublicBaseUrl=$WEB_URL` でもう一度デプロイする | web/DEPLOY.md 3.2 の 3 |
| CORS（直結だけ） | API Gateway の CORS に SPA のオリジンを入れる（暫定。`api.yaml` に CORS の設定が入るまで） | web/DEPLOY.md 5章 |
| SPA のアップロード | 環境の発行方式（変数 `GRANT_MODE`。既定 `page`）の `web-dist-{方式}` を使う。`config.json`（`apiBaseUrl`（統合では `""`）、`maxImageBytes`）を作り、`dist` と一緒に S3 に置いて、CloudFront のキャッシュを消す | web/DEPLOY.md 6章 |
| スモークテスト | SPA と `config.json` が取れること、発行できること（直結: API に直接送り、CORS のヘッダーが付くこと。統合: CloudFront の `/v1/tickets` に送り、`qrUrl` が CloudFront の URL であること）、QR 画像 API が PNG を返すこと。URL はジョブのサマリーに出す | {impl}/DEPLOY.md 7章、web/DEPLOY.md 7章 |

同じ環境・同じ実装のデプロイは、同時に1つだけ動く（`concurrency`。実行中のものは取り消さない）。

## 2. 準備（初回だけ）

### AWS 側

| 準備 | 方法 |
|---|---|
| 成果物バケット | DEPLOY.md 2章 |
| 署名用の salt | {impl}/DEPLOY.md 3章（`/ticketqr/{impl}/signing-salt`。実装ごと） |
| GitHub の OIDC プロバイダー | IAM の ID プロバイダーに `token.actions.githubusercontent.com`（対象者 `sts.amazonaws.com`）を追加する（アカウントに1つ） |
| デプロイ用の IAM ロール | 下の信頼ポリシーと権限で作る（環境ごとに分けてもよい） |

信頼ポリシー（このリポジトリの、指定した environment のジョブだけが引き受けられる）:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:rxsxkxd/pk:environment:dev"
      }
    }
  }]
}
```

ロールに必要な権限（目安。最初は広めに付けて動かし、CloudTrail を見て絞る）:

| 対象 | 権限 |
|---|---|
| CloudFormation | `cloudformation:*`（スタック `ticketqr-*` に限定する） |
| IAM（Lambda の実行ロールをスタックが作るため） | `iam:CreateRole` / `DeleteRole` / `GetRole` / `PassRole` / `PutRolePolicy` / `DeleteRolePolicy` / `AttachRolePolicy` / `DetachRolePolicy`（ロール名 `ticketqr-*` に限定する） |
| Lambda・API Gateway・ログ | `lambda:*`、`apigateway:*`（`/apis*`）、`logs:CreateLogGroup` / `DeleteLogGroup` / `PutRetentionPolicy` |
| S3 | 成果物バケットへの `s3:PutObject`。Web のバケットの作成と、`s3:PutObject` / `DeleteObject` / `ListBucket` / `PutBucketPolicy` |
| CloudFront | ディストリビューション、OAC、Response Headers Policy の作成・更新、`cloudfront:CreateInvalidation` |
| SSM | 不要（salt はデプロイの時点では読まない。Lambda の実行ロールが実行時に読む） |

### GitHub 側

| 設定 | 内容 |
|---|---|
| environment | `dev`、`prod` など。`prod` には承認者（Required reviewers）を設定する |
| environment の変数（Variables） | `AWS_REGION`（例: `ap-northeast-1`）、`AWS_DEPLOY_ROLE_ARN`、`ARTIFACT_BUCKET`、`GRANT_MODE`（任意。SPA の発行方式 `page` / `inline` / `form`。既定は `page`。`form` では CSP の `form-action` も自動で設定する）、`MAX_IMAGE_BYTES`（任意） |

秘密の値（Secrets）は使わない。ロールの ARN やバケット名は秘密ではないので、変数に入れる。

## 3. ロールバック

前のコミットを選んで、デプロイのワークフローをもう一度実行する（`Run workflow` でブランチやタグを選ぶ）。zip の接頭辞はコミットごとに違うので、前のコードに戻る。CloudFormation の更新が失敗したときは、スタックが自動で元に戻る。
