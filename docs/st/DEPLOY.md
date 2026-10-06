# AWS デプロイ手順（全体）

デプロイの手順は、デプロイするものごとにフォルダーに分けてある。この文書には、全体の構成と、どれにも共通の準備だけを書く。API の設計は [DESIGN.md](DESIGN.md)、画面とエンドポイントの名前は [PAGES.md](PAGES.md) を参照。

| 手順書 | デプロイするもの | スタック |
|---|---|---|
| [go/DEPLOY.md](go/DEPLOY.md) | チケット API の Go 版（と、example.com の QR） | `ticketqr-go`、`ticketqr-go-example` |
| [node/DEPLOY.md](node/DEPLOY.md) | チケット API の Node 版（と、example.com の QR） | `ticketqr-node`、`ticketqr-node-example` |
| [web/DEPLOY.md](web/DEPLOY.md) | Web フロントエンド（SPA。S3 + CloudFront）と、API の CORS 設定 | `ticketqr-web-{impl}` |
| この文書 | 共通の準備（1・2章）、画像解析サーバーのスタブ（3章） | `ticketqr-analyzer-stub-{stub}` |
| [CI.md](CI.md) | GitHub Actions からのデプロイ（上の手順を自動で実行する） | - |
| [CD_CI.md](CD_CI.md) | 構成案: CI は GitHub Actions、CD（デプロイ）は CodePipeline / CodeBuild | `ticketqr-st-pipeline` |

## 0. 全体の構成と順番

```
Web フロントエンド: CloudFront（OAC）+ 非公開の S3（web.yaml・ticketqr-web-{impl}）                web/DEPLOY.md
  └─ SPA の JS が fetch / <img> で呼ぶ（CORS で SPA のオリジンを許可）
チケット API: API Gateway HTTP API ticketqr-{impl}（api.yaml）                                   go/DEPLOY.md・node/DEPLOY.md
 ├─ POST /v1/tickets/qr-inline        ┐  QR 同梱付与 API
 ├─ POST /v1/tickets                  ├→ Lambda ticketqr-{impl}-tickets  チケット付与 API
 ├─ GET  /v1/tickets/{ticketCode}/view ┘                                   チケット表示ページ
 └─ GET  /v1/tickets/{ticketCode}/qr   → Lambda ticketqr-{impl}-get-qr   QR 画像 API
example: API Gateway HTTP API ticketqr-{impl}-example（example.yaml。チケット API とは無関係）
 └─ GET  /v1/example/qr                → Lambda ticketqr-{impl}-example-qr
画像解析サーバーのスタブ: Lambda + Function URL（analyzer-stub/template.yaml。この文書の3章。任意）
Parameter Store（SecureString。スタックの外で管理）: /ticketqr/{impl}/signing-salt、/ticketqr/analyzer-stub/{stub}/api-key
S3（スタックの外で管理）: 成果物バケット ticketqr-artifacts-{account}-{region}（この文書の2章）
```

`{impl}` は API の実装（`go` / `node`）。実装ごとに、別のスタック・別の URL になる。

順番:

1. この文書の 1章（前提）と 2章（成果物バケット）
2. チケット API: [go/DEPLOY.md](go/DEPLOY.md) か [node/DEPLOY.md](node/DEPLOY.md)（`$API_URL` が決まる）
3. Web フロントエンド: [web/DEPLOY.md](web/DEPLOY.md)（`$API_URL` を使い、API の CORS に SPA のオリジンを入れる）
4. 必要なら: 画像解析サーバーのスタブ（この文書の 3章）をデプロイし、API を `http` モードに切り替える（各実装の DEPLOY.md 6章）

> 現在の実装の状態: Go 版・Node 版とも実装済み（同じテンプレートでデプロイでき、`Impl` パラメータで切り替える）。画像解析は `mock`（プロセス内で常に valid）と `http`（画像解析サーバーに POST）から選ぶ。`ALLOWED_ORIGINS`（Origin の照合）は未実装（E2E.md 4章）。

## 1. 前提（共通）

- AWS CLI v2 と、デプロイ先アカウントの認証情報
- 作業ディレクトリは `docs/st`（どの手順書も、テンプレートやテスト画像を `docs/st` からの相対パスで参照する）
- ビルドに必要なもの（Go・Node.js など）は、各手順書の前提を参照

```sh
cd docs/st
export AWS_REGION=ap-northeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### デプロイする人に必要な権限（目安）

| 対象 | 権限 |
|---|---|
| API（go / node） | `iam:CreateRole` / `PassRole` / `PutRolePolicy` / `AttachRolePolicy`、`lambda:*`、`apigateway:*`（`/apis*`）、`logs:CreateLogGroup` / `PutRetentionPolicy`、`ssm:PutParameter` / `GetParameter`、`s3:PutObject`（成果物バケット）、`cloudformation:*`（CloudFormation の場合） |
| Web | `s3:CreateBucket` / `PutBucketPolicy` / `PutObject` / `DeleteObject` / `ListBucket`、`cloudfront:*`（ディストリビューション、OAC、Response Headers Policy、無効化）、`apigateway:*`（CORS の設定） |

GitHub Actions から OIDC でデプロイするときのロールの権限は、CI.md 4.2。

## 2. 成果物バケットの作成（初回だけ）

Lambda の zip を置く S3 バケット。CloudFormation でデプロイするときに使う（Go 版・Node 版・スタブで共通）。

```sh
export ARTIFACT_BUCKET=ticketqr-artifacts-$ACCOUNT_ID-$AWS_REGION
aws s3api create-bucket --bucket $ARTIFACT_BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_REGION
aws s3api put-public-access-block --bucket $ARTIFACT_BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket $ARTIFACT_BUCKET --versioning-configuration Status=Enabled
```

各スタックは、zip をデプロイごとに別の接頭辞（例: `ticketqr/go/<git sha>`）で置く。古い zip は、ロールバックのために消さずに残す。

## 3. 画像解析サーバーのスタブ（任意。Go 版・Node 版で共通）

本物の画像解析サーバーができるまで、API の `http` モードの接続先に使う（[analyzer-stub/DESIGN.md](analyzer-stub/DESIGN.md)。解析はせず常に valid を返す）。スタブと API キーをここで用意し、API の切り替えは各実装の DEPLOY.md 6章で行う。

### 3.1 API キーを作る（初回だけ）

スタブと API の両方が読む API キーを、Parameter Store の SecureString に作る（CloudFormation は SecureString を作れないため、CLI で作る）。

```sh
export STUB_IMPL=node   # スタブの実装: node / rust（どちらも同じ動き。analyzer-stub/DESIGN.md 5・6章）
export ANALYZER_KEY_PARAM=/ticketqr/analyzer-stub/$STUB_IMPL/api-key

umask 077
KEY_FILE=$(mktemp)
openssl rand -hex 20 | tr -d '\n' > "$KEY_FILE"
aws ssm put-parameter --name $ANALYZER_KEY_PARAM --type SecureString \
  --description "API key for the image analysis stub ($STUB_IMPL)" --value file://"$KEY_FILE"
rm -f "$KEY_FILE"
```

### 3.2 スタブをデプロイする（初回、またはスタブを更新するとき）

```sh
npm --prefix analyzer-stub/node run build     # Rust 版は: analyzer-stub/rust/build.sh
export STUB_PREFIX=analyzer-stub/$STUB_IMPL/$(git rev-parse --short HEAD)$(git diff --quiet || echo -dirty-$(date +%s))
aws s3 cp analyzer-stub/$STUB_IMPL/dist/analyzer-stub.zip s3://$ARTIFACT_BUCKET/$STUB_PREFIX/analyzer-stub.zip

aws cloudformation deploy --stack-name ticketqr-analyzer-stub-$STUB_IMPL \
  --template-file analyzer-stub/template.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides Impl=$STUB_IMPL ArtifactBucket=$ARTIFACT_BUCKET ArtifactPrefix=$STUB_PREFIX \
    ApiKeyParameterName=$ANALYZER_KEY_PARAM

export ANALYZER_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-analyzer-stub-$STUB_IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='AnalyzeUrl'].OutputValue" --output text)
echo $ANALYZER_URL
```

スタブを直接 curl で叩くときは、`aws ssm get-parameter --name $ANALYZER_KEY_PARAM --with-decryption --query Parameter.Value --output text` で API キーの値を取り出す。

この後、API を `http` モードに切り替える: [go/DEPLOY.md](go/DEPLOY.md) / [node/DEPLOY.md](node/DEPLOY.md) の 6章（`ANALYZER_URL`・`ANALYZER_KEY_PARAM`・`STUB_IMPL` を使う）。

### 3.3 スタブを削除する

API を `mock` に戻してから削除する（`http` のまま削除すると、発行の API がすべて 502 になる）。

```sh
aws cloudformation delete-stack --stack-name ticketqr-analyzer-stub-$STUB_IMPL
aws ssm delete-parameter --name $ANALYZER_KEY_PARAM   # API キーはスタックの外にあるので別に削除する
```

## 4. まだ対応していないもの（今後、各手順書に追加する）

| 項目 | 状態 |
|---|---|
| `ALLOWED_ORIGINS`（Origin の照合） | 未実装（E2E.md 4.2）。実装したら、API の Lambda の環境変数を追加する（go / node） |
| HTTP API の CORS 設定のテンプレート化 | 今は web/DEPLOY.md 5章の `update-api` で設定する（スタックの外からの変更）。`api.yaml` に `AllowedOrigins` パラメータと `CorsConfiguration` を追加する |
| Web フロントエンドの独自ドメイン | CloudFront の代替ドメイン名と、us-east-1 の ACM 証明書を `web.yaml` に追加する。そのときは CORS の `AllowOrigins` も独自ドメインにする |
| API の独自ドメイン | `PublicBaseUrl` パラメータだけ用意してある。ACM 証明書と `AWS::ApiGatewayV2::DomainName`、`ApiMapping` は別途追加する |
| 本物の画像解析サーバーへの接続 | HTTP クライアントは Go 版・Node 版とも、仮のプロトコル（analyzer-stub/DESIGN.md 3）で実装済み。本物の仕様が決まったら、レスポンスの解釈部分（Go: `parseResponse`、Node: `parseAnalyzerResponse`）を差し替える。VPC の設定が必要になる可能性がある |
| WAF | HTTP API に直接は付けられない。手前に CloudFront を置く場合に検討する |
| GitHub Actions からのデプロイ | `.github/workflows/st-deploy.yml` を定義済み（未検証）。OIDC で IAM ロールを引き受け、各手順書の CloudFormation の手順を実行する。準備と流れは [CI.md](CI.md) 4章 |
