# AWS デプロイ手順

API の設計は [DESIGN.md](DESIGN.md) を参照。デプロイの方法は2つある。

| 方法 | 用途 |
|---|---|
| [手動（AWS CLI）](#3-手動デプロイaws-cli) | 一度試すとき、構成を理解するとき |
| [CloudFormation](#4-cloudformation-デプロイ) | 繰り返しデプロイするとき、環境を複製するとき、CI からデプロイするとき（推奨） |

どちらの方法でも、出来上がる構成は同じになる。チケット API と、example.com の QR エンドポイント（4.8）は、**別々の HTTP API・別々のスタック**にする。

```
チケット API: API Gateway HTTP API ticketqr-{impl}（$default ステージ、自動デプロイ、スロットリング）
 ├─ POST /v1/tickets/qr-inline        ┐
 ├─ POST /v1/tickets                  ├→ Lambda ticketqr-{impl}-tickets（画像解析・採番・ビュー）
 ├─ GET  /v1/tickets/{ticketCode}/view ┘
 └─ GET  /v1/tickets/{ticketCode}/qr   → Lambda ticketqr-{impl}-get-qr（QR 画像の生成）
example: API Gateway HTTP API ticketqr-{impl}-example（4.8。チケット API とは無関係）
 └─ GET  /v1/example/qr                → Lambda ticketqr-{impl}-example-qr
チケット系（上の2関数）: provided.al2023 / arm64 / 256MB、パッケージ ticketqr.zip を共有（どのハンドラを呼ぶかは routeKey で決まる）
                      実行ロールは Parameter Store の salt（と、http モードのときは解析サーバーの API キー）だけを読める
example-qr:           provided.al2023 / arm64 / 128MB、別パッケージ exampleqr.zip、別テンプレート example.yaml、設定もシークレットも不要
                      実行ロールはログ出力だけ（チケット系とは別のロール）
Web フロントエンド:     CloudFront（OAC）+ 非公開の S3。別テンプレート web.yaml・別スタック ticketqr-web-{impl}（6章）
Parameter Store（SecureString）: /ticketqr/{impl}/signing-salt（スタックの外で管理する）
```

> 現在の実装の状態: Go 版・Node 版とも実装済み（同じ手順でデプロイできる。2.1.1）。画像解析は `ANALYZER_MODE=mock`（プロセス内で常に valid）と `ANALYZER_MODE=http`（画像解析サーバーに POST）から選ぶ（どちらも Go 版・Node 版で対応）（[4.7](#47-画像解析サーバーの切り替えanalyzer_mode)）。`ALLOWED_ORIGINS`（Origin の照合）は未実装（E2E.md 4章）。Web フロントエンド（SPA）の S3 + CloudFront へのデプロイは [6章](#6-web-フロントエンドs3--cloudfront)（API の CORS 設定を含む）。

## 1. 前提

- AWS CLI v2 と、デプロイ先アカウントの認証情報
- Go（`docs/st/go/go.mod` のバージョン）、`make`、`zip`、`openssl`
- 作業ディレクトリは `docs/st`

```sh
cd docs/st
export AWS_REGION=ap-northeast-1
export IMPL=go
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### デプロイする人に必要な権限（目安）

`iam:CreateRole` / `PassRole` / `PutRolePolicy` / `AttachRolePolicy`、`lambda:*`、`apigateway:*`（`/apis*`）、`logs:CreateLogGroup` / `PutRetentionPolicy`、`ssm:PutParameter` / `GetParameter`、`s3:PutObject`（CloudFormation の場合は、成果物バケットへの書き込み）、`cloudformation:*`（CloudFormation の場合）。

## 2. 共通の準備

### 2.1 ビルド

```sh
make -C go test
make -C go build
ls go/bin/*.zip   # ticketqr.zip（チケット系4エンドポイント）、exampleqr.zip（example.com の QR）
```

### 2.1.1 Node 版の場合

Node 版も zip の名前と構成は同じ。以降の手順は、次の表の項目だけを読み替える。

```sh
npm --prefix node ci
npm --prefix node test && npm --prefix node run typecheck
npm --prefix node run build
ls node/dist/*.zip   # ticketqr.zip、exampleqr.zip
```

| 項目 | Go 版 | Node 版 |
|---|---|---|
| `IMPL` | `go` | `node` |
| zip の場所 | `go/bin/*.zip` | `node/dist/*.zip` |
| 手動デプロイ（3.3、4.8）の `--runtime` / `--handler` | `provided.al2023` / `bootstrap` | `nodejs24.x` / `index.handler` |
| CloudFormation（4.4） | `Impl=go` | `Impl=node`（Runtime と Handler はテンプレートの `ImplMap` が切り替える） |

salt のパラメータ（2.2）は実装ごとに作る（`/ticketqr/node/signing-salt`）。

### 2.2 署名用 salt の作成（初回だけ）

salt はスタックの外で作る。理由は2つある。
- スタックを作り直しても salt が変わらないようにするため（salt が変わると、発行済みのビュー / QR の URL がすべて無効になる）
- salt の値がテンプレートやパラメータに出ないようにするため

```sh
export SALT_PARAM=/ticketqr/$IMPL/signing-salt

umask 077
SALT_FILE=$(mktemp)
printf '{"current":"%s"}' "$(openssl rand -base64 32)" > "$SALT_FILE"

aws ssm put-parameter \
  --name $SALT_PARAM \
  --type SecureString \
  --description "Ticket QR signing salt ($IMPL)" \
  --value file://"$SALT_FILE"

rm -f "$SALT_FILE"
```

- Parameter Store の SecureString（Standard ティア、無料）に、`{"current":"…","previous":"…"}` の JSON を保存する。CloudFormation は SecureString を作れないので、CLI で作る
- salt を引数に直接書かない（シェルの履歴やプロセス一覧に残るため。`--value file://…` でファイルから渡す）
- 暗号化は既定の `aws/ssm` キーを使う。この場合、実行ロールには `ssm:GetParameter` だけを付ければよい。独自の KMS キーを使う場合は、実行ロールに `kms:Decrypt` を追加する
- Go 版と Node 版で同じ salt を使う必要はない（スタックごとに URL が別になるため）

## 3. 手動デプロイ（AWS CLI）

### 3.1 Lambda の実行ロール

```sh
ROLE_NAME=ticketqr-$IMPL-lambda

aws iam create-role --role-name $ROLE_NAME \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam attach-role-policy --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws iam put-role-policy --role-name $ROLE_NAME --policy-name read-signing-salt \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"ssm:GetParameter\",\"Resource\":\"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter$SALT_PARAM\"}]}"

export ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text)
sleep 10   # 作ったばかりの IAM ロールが反映されるまで待つ
```

### 3.2 HTTP API の作成（先に URL を決める）

Lambda の環境変数 `PUBLIC_BASE_URL` に API の URL が必要なので、API を先に作る。

```sh
read API_ID API_URL < <(aws apigatewayv2 create-api \
  --name ticketqr-$IMPL --protocol-type HTTP \
  --query '[ApiId,ApiEndpoint]' --output text)
export API_ID API_URL
echo $API_URL   # https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com
```

### 3.3 Lambda 関数（チケット系は2つ）

| 関数 | 担当ルート | タイムアウト |
|---|---|---|
| `ticketqr-$IMPL-tickets` | A `POST /v1/tickets/qr-inline`、B-1 `POST /v1/tickets`、B-3 `GET .../view`（画像解析・採番・ビュー） | 15秒 |
| `ticketqr-$IMPL-get-qr` | B-2 `GET .../qr`（QR 画像の生成） | 5秒 |

```sh
aws logs create-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-tickets
aws logs put-retention-policy --log-group-name /aws/lambda/ticketqr-$IMPL-tickets --retention-in-days 30
aws lambda create-function \
  --function-name ticketqr-$IMPL-tickets \
  --runtime provided.al2023 --architectures arm64 --handler bootstrap \
  --role $ROLE_ARN --memory-size 256 --timeout 15 \
  --zip-file fileb://go/bin/ticketqr.zip \
  --environment "Variables={PUBLIC_BASE_URL=$API_URL,ANALYZER_MODE=mock,SIGNING_SALT_PARAMETER_NAME=$SALT_PARAM,TICKET_SUFFIX_LENGTH=8}" \
  --query FunctionArn --output text

aws logs create-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-get-qr
aws logs put-retention-policy --log-group-name /aws/lambda/ticketqr-$IMPL-get-qr --retention-in-days 30
aws lambda create-function \
  --function-name ticketqr-$IMPL-get-qr \
  --runtime provided.al2023 --architectures arm64 --handler bootstrap \
  --role $ROLE_ARN --memory-size 256 --timeout 5 \
  --zip-file fileb://go/bin/ticketqr.zip \
  --environment "Variables={PUBLIC_BASE_URL=$API_URL,ANALYZER_MODE=mock,SIGNING_SALT_PARAMETER_NAME=$SALT_PARAM,TICKET_SUFFIX_LENGTH=8}" \
  --query FunctionArn --output text
```

- 2関数とも同じ zip（`ticketqr.zip`）を使う。どのハンドラーを呼ぶかは、イベントの `routeKey` で決まる（コードは関数の分け方に依存しない）
- `tickets` は、画像解析の待ち時間（最大5秒程度）を見込んで 15秒にしている。B-3（ビュー）も同じ関数なので 15秒になるが、実際の処理は数ミリ秒で終わる
- `get-qr` を分けているのは、ブラウザの `<img>` から呼ばれる QR 生成を、画像解析の同時実行数の上限から切り離すため
- 画像解析サーバーを守るために同時実行数に上限をかける場合は、次のコマンドを使う: `aws lambda put-function-concurrency --function-name ticketqr-$IMPL-tickets --reserved-concurrent-executions 10`（B-3 のビュー表示もこの上限の対象に入る）

### 3.4 ルート・統合・呼び出し権限

1つの統合（integration）を複数のルートから使う。

```sh
# tickets: 統合1つに3ルート
TICKETS_ARN=$(aws lambda get-function --function-name ticketqr-$IMPL-tickets --query Configuration.FunctionArn --output text)
TICKETS_INTEGRATION=$(aws apigatewayv2 create-integration --api-id $API_ID \
  --integration-type AWS_PROXY --integration-uri $TICKETS_ARN \
  --payload-format-version 2.0 --timeout-in-millis 20000 \
  --query IntegrationId --output text)
aws apigatewayv2 create-route --api-id $API_ID --route-key 'POST /v1/tickets/qr-inline' --target integrations/$TICKETS_INTEGRATION
aws apigatewayv2 create-route --api-id $API_ID --route-key 'POST /v1/tickets' --target integrations/$TICKETS_INTEGRATION
aws apigatewayv2 create-route --api-id $API_ID --route-key 'GET /v1/tickets/{ticketCode}/view' --target integrations/$TICKETS_INTEGRATION
aws lambda add-permission --function-name ticketqr-$IMPL-tickets \
  --statement-id apigateway-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*"

# get-qr: 統合1つに1ルート
GET_QR_ARN=$(aws lambda get-function --function-name ticketqr-$IMPL-get-qr --query Configuration.FunctionArn --output text)
GET_QR_INTEGRATION=$(aws apigatewayv2 create-integration --api-id $API_ID \
  --integration-type AWS_PROXY --integration-uri $GET_QR_ARN \
  --payload-format-version 2.0 --timeout-in-millis 20000 \
  --query IntegrationId --output text)
aws apigatewayv2 create-route --api-id $API_ID --route-key 'GET /v1/tickets/{ticketCode}/qr' --target integrations/$GET_QR_INTEGRATION
aws lambda add-permission --function-name ticketqr-$IMPL-get-qr \
  --statement-id apigateway-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*"
```

### 3.5 ステージ（スロットリングを含む）

```sh
aws apigatewayv2 create-stage --api-id $API_ID --stage-name '$default' --auto-deploy \
  --default-route-settings ThrottlingRateLimit=50,ThrottlingBurstLimit=100
```

この時点で API が公開される。動作確認は [5章](#5-動作確認)。

### 3.6 コードの更新

```sh
make -C go build
aws lambda update-function-code --function-name ticketqr-$IMPL-tickets \
  --zip-file fileb://go/bin/ticketqr.zip --query LastUpdateStatus --output text
aws lambda update-function-code --function-name ticketqr-$IMPL-get-qr \
  --zip-file fileb://go/bin/ticketqr.zip --query LastUpdateStatus --output text
```

環境変数を変えるときは `aws lambda update-function-configuration --environment ...` を使う。指定した変数で全体が置き換わるので、既存の変数もすべて指定し直す。

### 3.7 削除

```sh
aws apigatewayv2 delete-api --api-id $API_ID
aws lambda delete-function --function-name ticketqr-$IMPL-tickets
aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-tickets
aws lambda delete-function --function-name ticketqr-$IMPL-get-qr
aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-get-qr
aws iam delete-role-policy --role-name ticketqr-$IMPL-lambda --policy-name read-signing-salt
aws iam detach-role-policy --role-name ticketqr-$IMPL-lambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ticketqr-$IMPL-lambda
# salt のパラメータは、必要がなくなったときだけ削除する（aws ssm delete-parameter --name $SALT_PARAM）
```

## 4. CloudFormation デプロイ

テンプレート（どちらも cfn-lint で検証済み）:
- [`infra/cloudformation/api.yaml`](infra/cloudformation/api.yaml): チケット API（4.1〜4.7）
- [`infra/cloudformation/example.yaml`](infra/cloudformation/example.yaml): example.com の QR エンドポイント（4.8）

### 4.1 主なパラメータ

| パラメータ | 既定値 | 内容 |
|---|---|---|
| `Impl` | `go` | `go` / `node`。実装ごとにスタックを分ける |
| `ArtifactBucket` | - | Lambda の zip を置く S3 バケット |
| `ArtifactPrefix` | - | zip のキーの接頭辞。**デプロイのたびに変える**（例: `ticketqr/go/<git sha>`） |
| `SigningSaltParameterName` | - | 2.2 で作った salt のパラメータ名（例: `/ticketqr/go/signing-salt`） |
| `AnalyzerMode` | `mock` | 画像解析クライアントの種類。`mock`（プロセス内で常に valid）/ `http`（`AnalyzerUrl` に POST）。4.7 |
| `AnalyzerUrl` | 空 | `AnalyzerMode=http` のときの POST 先（例: スタブのスタックの出力 `AnalyzeUrl`） |
| `AnalyzerApiKeyParameterName` | 空 | `AnalyzerMode=http` のときの API キーのパラメータ名（例: `/ticketqr/analyzer-stub/node/api-key`）。指定すると、Lambda の実行ロールに読み取り権限が付く |
| `TicketSuffixLength` | `8` | suffix の桁数 |
| `PublicBaseUrl` | 空 | 独自ドメインを使う場合に指定する。空なら execute-api の URL を自動で使う |
| `ThrottlingRateLimit` / `ThrottlingBurstLimit` | `50` / `100` | 全ルートに共通のスロットリング |
| `IssueReservedConcurrency` | `-1`（設定しない） | `tickets` 関数に予約する同時実行数（画像解析サーバーの保護用） |
| `LogRetentionDays` | `30` | Lambda と API のアクセスログの保持日数 |

### 4.2 成果物バケットの作成（初回だけ）

```sh
export ARTIFACT_BUCKET=ticketqr-artifacts-$ACCOUNT_ID-$AWS_REGION
aws s3api create-bucket --bucket $ARTIFACT_BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_REGION
aws s3api put-public-access-block --bucket $ARTIFACT_BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket $ARTIFACT_BUCKET --versioning-configuration Status=Enabled
```

### 4.3 zip のアップロード

```sh
make -C go build
export ARTIFACT_PREFIX=ticketqr/$IMPL/$(git rev-parse --short HEAD)$(git diff --quiet || echo -dirty-$(date +%s))
aws s3 cp go/bin/ticketqr.zip s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX/ticketqr.zip     # Node 版は node/dist/ticketqr.zip
aws s3 cp go/bin/exampleqr.zip s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX/exampleqr.zip   # Node 版は node/dist/exampleqr.zip
```

CloudFormation は、`S3Key` が変わらない限り Lambda のコードを更新しない。そのため、デプロイのたびに接頭辞を変える。コミットしていない変更がある場合は、接頭辞に `-dirty-<時刻>` を付ける。

### 4.4 スタックのデプロイ（作成と更新は同じコマンド）

```sh
aws cloudformation deploy \
  --stack-name ticketqr-$IMPL \
  --template-file infra/cloudformation/api.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Impl=$IMPL \
    ArtifactBucket=$ARTIFACT_BUCKET \
    ArtifactPrefix=$ARTIFACT_PREFIX \
    SigningSaltParameterName=$SALT_PARAM

export API_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
echo $API_URL
```

- 変更内容を先に確認したいときは `--no-execute-changeset` を付ける。表示された変更セットを確認し、`aws cloudformation execute-change-set` で反映する
- 失敗したときは、`aws cloudformation describe-stack-events --stack-name ticketqr-$IMPL` で原因を確認する

### 4.5 ロールバック

以前の `ArtifactPrefix` を指定して、4.4 をもう一度実行する（S3 上の古い zip は消さずに残しておく）。

### 4.6 削除

```sh
aws cloudformation delete-stack --stack-name ticketqr-$IMPL
aws cloudformation wait stack-delete-complete --stack-name ticketqr-$IMPL
```

スタックの外にある salt のパラメータと成果物バケットは残る。

### 4.7 画像解析サーバーの切り替え（ANALYZER_MODE）

| モード | 動き | 必要なパラメータ | 対応する実装 |
|---|---|---|---|
| `mock`（既定） | API の中で、通信せずに常に valid を返す | なし | Go 版・Node 版 |
| `http` | `AnalyzerUrl` に画像をそのまま POST する（`application/octet-stream`、`x-api-key` 付き。1回5秒でタイムアウトし、5xx・タイムアウト・通信エラーのときだけ1回リトライ） | `AnalyzerUrl`、`AnalyzerApiKeyParameterName` | Go 版・Node 版 |

本物の画像解析サーバーができるまでは、`http` の接続先に画像解析サーバーのスタブ（[analyzer-stub/DESIGN.md](analyzer-stub/DESIGN.md)。解析はせず常に valid を返す）を使う。

#### 手順1: スタブの API キーを作る（初回だけ）

スタブと API の両方が読む API キーを、Parameter Store の SecureString に作る（CloudFormation は SecureString を作れないため、CLI で作る）。

```sh
cd docs/st
export STUB_IMPL=node   # スタブの実装: node / rust（どちらも同じ動き。analyzer-stub/DESIGN.md 5・6章）
export ANALYZER_KEY_PARAM=/ticketqr/analyzer-stub/$STUB_IMPL/api-key

umask 077
KEY_FILE=$(mktemp)
openssl rand -hex 20 | tr -d '\n' > "$KEY_FILE"
aws ssm put-parameter --name $ANALYZER_KEY_PARAM --type SecureString \
  --description "API key for the image analysis stub ($STUB_IMPL)" --value file://"$KEY_FILE"
rm -f "$KEY_FILE"
```

#### 手順2: スタブをデプロイする（初回、またはスタブを更新するとき）

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

#### 手順3: API を `http` モードでデプロイする

4.3 で zip（Go 版は `go/bin/*.zip`、Node 版は `node/dist/*.zip`）をアップロードしたうえで、4.4 のコマンドにパラメータを3つ足す。以下は Go 版の例（Node 版は `IMPL=node`）。

```sh
export IMPL=go
aws cloudformation deploy \
  --stack-name ticketqr-$IMPL \
  --template-file infra/cloudformation/api.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Impl=$IMPL \
    ArtifactBucket=$ARTIFACT_BUCKET \
    ArtifactPrefix=$ARTIFACT_PREFIX \
    SigningSaltParameterName=$SALT_PARAM \
    AnalyzerMode=http \
    AnalyzerUrl=$ANALYZER_URL \
    AnalyzerApiKeyParameterName=$ANALYZER_KEY_PARAM
```

- `tickets` と `get-qr` の両方の Lambda に `ANALYZER_MODE`、`ANALYZER_URL`、`ANALYZER_API_KEY_PARAMETER_NAME` が入り、実行ロールに API キーの読み取り権限が付く（2つの関数は同じ初期化処理を通るため、`get-qr` にも必要）
- `aws cloudformation deploy` は、指定しなかったパラメータを既定値に戻す。`http` のまま別の変更をデプロイするときも、3つのパラメータを毎回指定する

#### 手順4: 動作確認

```sh
curl -s -F image=@testdata/images/photo.jpg $API_URL/v1/tickets/qr-inline | head -c 120; echo   # 201（スタブ経由で valid）

# スタブが受け取った画像のハッシュが、送ったファイルと一致することを確認する（画像が加工されずに届いている）
shasum -a 256 testdata/images/photo.jpg
aws logs tail /aws/lambda/ticketqr-analyzer-stub-$STUB_IMPL --since 5m | grep '"msg":"analyzed"'

# スタブにつながらない・API キーが合わないときは、API が 502 ANALYSIS_UPSTREAM_ERROR を返し、ログに原因が出る
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 5m | grep 'image analysis failed'
```

#### 手動デプロイ（3章）の場合

3.1 の実行ロールに API キーの読み取り権限を足し、2つの Lambda の環境変数に `ANALYZER_MODE=http`、`ANALYZER_URL`、`ANALYZER_API_KEY_PARAMETER_NAME` を加える。

```sh
aws iam put-role-policy --role-name ticketqr-$IMPL-lambda --policy-name read-analyzer-api-key \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"ssm:GetParameter\",\"Resource\":\"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter$ANALYZER_KEY_PARAM\"}]}"

aws lambda update-function-configuration --function-name ticketqr-$IMPL-tickets \
  --environment "Variables={PUBLIC_BASE_URL=$API_URL,ANALYZER_MODE=http,ANALYZER_URL=$ANALYZER_URL,ANALYZER_API_KEY_PARAMETER_NAME=$ANALYZER_KEY_PARAM,SIGNING_SALT_PARAMETER_NAME=$SALT_PARAM,TICKET_SUFFIX_LENGTH=8}" \
  --query LastUpdateStatus --output text
aws lambda update-function-configuration --function-name ticketqr-$IMPL-get-qr \
  --environment "Variables={PUBLIC_BASE_URL=$API_URL,ANALYZER_MODE=http,ANALYZER_URL=$ANALYZER_URL,ANALYZER_API_KEY_PARAMETER_NAME=$ANALYZER_KEY_PARAM,SIGNING_SALT_PARAMETER_NAME=$SALT_PARAM,TICKET_SUFFIX_LENGTH=8}" \
  --query LastUpdateStatus --output text
```

#### `mock` に戻す・スタブを削除する

```sh
# mock に戻す: 4.4 のコマンドを AnalyzerMode などを付けずに実行する（既定値の mock に戻る）
# スタブを削除する（API を mock に戻してから）
aws cloudformation delete-stack --stack-name ticketqr-analyzer-stub-$STUB_IMPL
aws ssm delete-parameter --name $ANALYZER_KEY_PARAM   # API キーはスタックの外にあるので別に削除する
```

API を `http` のままスタブを削除すると、画像の発行（A / B-1）がすべて 502 になる。

### 4.8 example.com の QR エンドポイント（別スタック・別 API）

`GET /v1/example/qr` は、チケット API とは無関係なエンドポイント。パッケージ（`exampleqr.zip`）、テンプレート（`example.yaml`）、HTTP API、実行ロールをすべて分け、チケット API とは独立して作成・削除できるようにする。設定もシークレットも使わないので、実行ロールはログ出力だけ。

#### CloudFormation

`exampleqr.zip` は 4.3 でチケット API の zip と一緒にアップロードしてある。

```sh
aws cloudformation deploy \
  --stack-name ticketqr-$IMPL-example \
  --template-file infra/cloudformation/example.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Impl=$IMPL \
    ArtifactBucket=$ARTIFACT_BUCKET \
    ArtifactPrefix=$ARTIFACT_PREFIX

export EXAMPLE_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-$IMPL-example \
  --query "Stacks[0].Outputs[?OutputKey=='ExampleQrUrl'].OutputValue" --output text)
echo $EXAMPLE_URL

# 削除
aws cloudformation delete-stack --stack-name ticketqr-$IMPL-example
```

| パラメータ | 既定値 | 内容 |
|---|---|---|
| `Impl` / `ArtifactBucket` / `ArtifactPrefix` | - | 4.1 と同じ |
| `ThrottlingRateLimit` / `ThrottlingBurstLimit` | `10` / `20` | example 用の HTTP API のスロットリング |
| `LogRetentionDays` | `30` | ログの保持日数 |

#### 手動（AWS CLI）

```sh
# 実行ロール（ログ出力だけ）
aws iam create-role --role-name ticketqr-$IMPL-example-lambda \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name ticketqr-$IMPL-example-lambda \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
EXAMPLE_ROLE_ARN=$(aws iam get-role --role-name ticketqr-$IMPL-example-lambda --query Role.Arn --output text)
sleep 10

# Lambda
aws logs create-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-example-qr
aws logs put-retention-policy --log-group-name /aws/lambda/ticketqr-$IMPL-example-qr --retention-in-days 30
EXAMPLE_FN_ARN=$(aws lambda create-function \
  --function-name ticketqr-$IMPL-example-qr \
  --runtime provided.al2023 --architectures arm64 --handler bootstrap \
  --role $EXAMPLE_ROLE_ARN --memory-size 128 --timeout 5 \
  --zip-file fileb://go/bin/exampleqr.zip \
  --query FunctionArn --output text)

# 専用の HTTP API・ルート・ステージ
read EXAMPLE_API_ID EXAMPLE_API_URL < <(aws apigatewayv2 create-api \
  --name ticketqr-$IMPL-example --protocol-type HTTP --query '[ApiId,ApiEndpoint]' --output text)
EXAMPLE_INTEGRATION=$(aws apigatewayv2 create-integration --api-id $EXAMPLE_API_ID \
  --integration-type AWS_PROXY --integration-uri $EXAMPLE_FN_ARN \
  --payload-format-version 2.0 --timeout-in-millis 10000 --query IntegrationId --output text)
aws apigatewayv2 create-route --api-id $EXAMPLE_API_ID --route-key 'GET /v1/example/qr' \
  --target integrations/$EXAMPLE_INTEGRATION
aws lambda add-permission --function-name ticketqr-$IMPL-example-qr \
  --statement-id apigateway-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$EXAMPLE_API_ID/*/*"
aws apigatewayv2 create-stage --api-id $EXAMPLE_API_ID --stage-name '$default' --auto-deploy \
  --default-route-settings ThrottlingRateLimit=10,ThrottlingBurstLimit=20
export EXAMPLE_URL=$EXAMPLE_API_URL/v1/example/qr

# コードの更新
aws lambda update-function-code --function-name ticketqr-$IMPL-example-qr \
  --zip-file fileb://go/bin/exampleqr.zip --query LastUpdateStatus --output text

# 削除
aws apigatewayv2 delete-api --api-id $EXAMPLE_API_ID
aws lambda delete-function --function-name ticketqr-$IMPL-example-qr
aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-example-qr
aws iam detach-role-policy --role-name ticketqr-$IMPL-example-lambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ticketqr-$IMPL-example-lambda
```

Node 版は、zip を `node/dist/exampleqr.zip`、`--runtime nodejs24.x --handler index.handler` に読み替える（2.1.1）。

## 5. 動作確認

動作確認には `testdata/images/` の小さな画像（JPEG / PNG / HEIC / HEIF / AVIF / WebP。各32×32）を使う。画像の形式は API が判定するので（Node 版はヘッダーを解析するため、先頭数バイトだけの偽の画像は 415 になる）、手元の写真を使ってもよい。

```sh
# パターンA → 201 JSON
curl -s -F image=@testdata/images/photo.jpg $API_URL/v1/tickets/qr-inline | head -c 200; echo

# パターンB-1 → 303 とビューの URL
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -F image=@testdata/images/photo.jpg $API_URL/v1/tickets); echo $LOC

# B-3 → 200 HTML、B-2 → 200 image/png
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' "$LOC"
QR=$(echo "$LOC" | sed 's#/view?#/qr?#')
curl -s -o /tmp/qr.png -w '%{http_code} %{content_type}\n' "$QR"

# 署名を改ざん → 403
curl -s -o /dev/null -w '%{http_code}\n' "${LOC%sig=*}sig=AAAAAAAAAAAAAAAAAAAAAA"

# example.com の QR → 200 image/png
curl -s -o /tmp/example.png -w '%{http_code} %{content_type}\n' $EXAMPLE_URL   # 4.8 の別 API
```

ブラウザで `$LOC` を開くと、QR の画面が表示される。

ログを見る:

```sh
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --follow
aws logs tail /aws/apigateway/ticketqr-$IMPL --since 10m   # CloudFormation の場合だけ（アクセスログ）
```

## 6. Web フロントエンド（S3 + CloudFront）

SPA（`web/`。[web/DESIGN.md](web/DESIGN.md)）を、非公開の S3 バケットに置き、CloudFront（OAC）経由で配信する。API とは**別のスタック・別のテンプレート**（`infra/cloudformation/web.yaml`）にする。

```
利用者のブラウザ ──HTTPS──▶ CloudFront（既定のルートオブジェクト index.html、セキュリティヘッダー）
                              └─ OAC ──▶ S3 バケット（非公開。index.html、assets/*、config.json）
SPA の JS ──fetch / <img>──▶ チケット API（3章・4章で作った HTTP API。CORS で SPA のオリジンを許可する）
```

| 項目 | 内容 |
|---|---|
| スタック名 | `ticketqr-web-$IMPL`（どちらの実装の API を使うかで分ける。SPA 自体は同じビルド） |
| S3 バケット | 非公開（パブリックアクセスはすべてブロック）。CloudFront の OAC だけが読める |
| CloudFront | HTTPS へリダイレクト、既定のルートオブジェクト `index.html`（hash モードのルーティングなので、ほかのパスを `index.html` に向ける設定は不要）、マネージドのキャッシュポリシー CachingOptimized |
| セキュリティヘッダー | Response Headers Policy で CSP・HSTS・`X-Content-Type-Options`・`Referrer-Policy: no-referrer`・`X-Frame-Options: DENY` を付ける（web/DESIGN.md 9章） |
| `config.json` | 環境ごとに作ってアップロードする（ビルドには埋め込まない）。API の URL と、使う発行方式（`modes`）を書く |

### 6.1 前提

- チケット API をデプロイ済みで、`$API_URL` が分かっていること（3章または4章）
- Node.js 24（SPA のビルド）、手動で削除する場合は `jq`
- デプロイする人の権限: 1章のものに加えて、`s3:CreateBucket` / `PutBucketPolicy` / `PutObject` / `DeleteObject` / `ListBucket`、`cloudfront:*`（ディストリビューション、OAC、Response Headers Policy、無効化）

```sh
echo $API_URL   # https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com（末尾の / は付けない）
export WORK=$(mktemp -d)   # 設定ファイルなどの一時置き場
```

### 6.2 ビルド

```sh
npm --prefix web ci
npm --prefix web test
npm --prefix web run build      # 型チェック（vue-tsc）とビルド → web/dist/
ls web/dist                     # index.html、assets/、config.json（ローカル開発用。アップロードしない）
```

`web/dist/config.json` は開発用の値（`apiBaseUrl` が空）なので、アップロードしない。環境ごとの `config.json` は 6.6 で作る。

### 6.3 S3 と CloudFront の作成: CloudFormation（推奨）

```sh
aws cloudformation deploy \
  --stack-name ticketqr-web-$IMPL \
  --template-file infra/cloudformation/web.yaml \
  --parameter-overrides \
    ApiBaseUrl=$API_URL

export WEB_BUCKET=$(aws cloudformation describe-stacks --stack-name ticketqr-web-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)
export DIST_ID=$(aws cloudformation describe-stacks --stack-name ticketqr-web-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" --output text)
export WEB_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-web-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='WebUrl'].OutputValue" --output text)
echo $WEB_URL   # https://dxxxxxxxxxxxxx.cloudfront.net
```

| パラメータ | 既定値 | 内容 |
|---|---|---|
| `ApiBaseUrl` | - | チケット API のオリジン（`$API_URL`）。CSP の `img-src` と `connect-src` に入る |
| `FormActionSource` | `'none'` | CSP の `form-action`。フォーム送信方式（`modes` の `form`）を有効にする環境だけ、`$API_URL` にする |
| `PriceClass` | `PriceClass_200` | CloudFront の配信地域（日本を含む） |

- CloudFront のディストリビューションの作成には、数分〜十数分かかる
- API の URL が変わったら、`ApiBaseUrl` を変えて同じコマンドを実行する（CSP が更新される）。`config.json` も作り直す（6.6）

### 6.4 S3 と CloudFront の作成: 手動（AWS CLI）

CloudFormation を使わない場合。6.3 と同じ構成を作る。

```sh
export WEB_BUCKET=ticketqr-web-$IMPL-$ACCOUNT_ID

# 非公開のバケット（新しいバケットは、パブリックアクセスのブロックと BucketOwnerEnforced が既定で有効）
aws s3api create-bucket --bucket $WEB_BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_REGION
aws s3api put-public-access-block --bucket $WEB_BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# OAC（CloudFront が S3 を署名付きで読む）
OAC_ID=$(aws cloudfront create-origin-access-control \
  --origin-access-control-config Name=ticketqr-web-$IMPL-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3 \
  --query OriginAccessControl.Id --output text)

# セキュリティヘッダー（CSP には API のオリジンを入れる）
cat > $WORK/headers.json <<EOF
{
  "Name": "ticketqr-web-$IMPL-headers",
  "SecurityHeadersConfig": {
    "ContentSecurityPolicy": {
      "ContentSecurityPolicy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: $API_URL; connect-src $API_URL; form-action 'none'; frame-ancestors 'none'",
      "Override": true
    },
    "ContentTypeOptions": { "Override": true },
    "FrameOptions": { "FrameOption": "DENY", "Override": true },
    "ReferrerPolicy": { "ReferrerPolicy": "no-referrer", "Override": true },
    "StrictTransportSecurity": { "AccessControlMaxAgeSec": 31536000, "IncludeSubdomains": false, "Override": true }
  }
}
EOF
HEADERS_ID=$(aws cloudfront create-response-headers-policy \
  --response-headers-policy-config file://$WORK/headers.json \
  --query ResponseHeadersPolicy.Id --output text)

# ディストリビューション
cat > $WORK/distribution.json <<EOF
{
  "CallerReference": "ticketqr-web-$IMPL-$(date +%s)",
  "Comment": "ticketqr-web-$IMPL SPA",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "HttpVersion": "http2and3",
  "PriceClass": "PriceClass_200",
  "Origins": { "Quantity": 1, "Items": [ {
    "Id": "s3",
    "DomainName": "$WEB_BUCKET.s3.$AWS_REGION.amazonaws.com",
    "OriginAccessControlId": "$OAC_ID",
    "S3OriginConfig": { "OriginAccessIdentity": "" }
  } ] },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"], "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] } },
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "ResponseHeadersPolicyId": "$HEADERS_ID"
  }
}
EOF
read DIST_ID DIST_DOMAIN < <(aws cloudfront create-distribution \
  --distribution-config file://$WORK/distribution.json \
  --query '[Distribution.Id,Distribution.DomainName]' --output text)
export DIST_ID WEB_URL=https://$DIST_DOMAIN

# バケットポリシー（このディストリビューションからの読み取りだけを許可する）
cat > $WORK/bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [ {
    "Sid": "AllowCloudFrontOAC",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$WEB_BUCKET/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DIST_ID" } }
  } ]
}
EOF
aws s3api put-bucket-policy --bucket $WEB_BUCKET --policy file://$WORK/bucket-policy.json

aws cloudfront wait distribution-deployed --id $DIST_ID   # 数分〜十数分
echo $WEB_URL
```

- `658327ea-f89d-4fab-a63d-7e88639e58f6` は、マネージドのキャッシュポリシー CachingOptimized の ID
- フォーム送信方式を有効にする環境では、`headers.json` の `form-action 'none'` を `form-action $API_URL` にする

### 6.5 チケット API の CORS 設定

SPA（`$WEB_URL`）と API（`$API_URL`）はオリジンが違う。SPA が発行の応答（JSON）を読めるように、**API Gateway の CORS 設定で SPA のオリジンを許可する**（E2E.md 4.3）。これがないと、メインの画面遷移方式が動かない。

```sh
# 手動デプロイ（3章）の API: $API_ID は 3.2 で取得したもの
# CloudFormation（4章）の API: 名前から API の ID を調べる
export API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='ticketqr-$IMPL'].ApiId | [0]" --output text)

aws apigatewayv2 update-api --api-id $API_ID \
  --cors-configuration "{\"AllowOrigins\":[\"$WEB_URL\"],\"AllowMethods\":[\"GET\",\"POST\"],\"MaxAge\":300}" \
  --query CorsConfiguration
```

- `fetch` の `FormData` 送信は単純リクエストなので、`AllowHeaders` は不要
- **CloudFormation で作った API の注意**: `api.yaml` にはまだ CORS の設定がない（7章「未対応のもの」）。上のコマンドはスタックの外からの変更になる。`api.yaml` に `AllowedOrigins` パラメータと `CorsConfiguration` を追加するまでの暫定の手順で、API のスタックを更新したあとに CORS が残っているかを確認する（`aws apigatewayv2 get-api --api-id $API_ID --query CorsConfiguration`）
- CORS が止めるのは、応答を JS から読むことだけ。ほかのサイトからの発行を止める Origin の照合（`ALLOWED_ORIGINS`）は未実装（E2E.md 4.2）

### 6.6 config.json の作成とアップロード

```sh
# 環境ごとの設定。modes は既定の画面遷移方式（page）だけ。オプションの方式を使う環境だけ "inline" / "form" を足す
cat > $WORK/config.json <<EOF
{ "apiBaseUrl": "$API_URL", "modes": ["page"] }
EOF

# assets/*（ファイル名にハッシュが入る）は長くキャッシュする。--delete で古いファイルを消す
aws s3 sync web/dist/ s3://$WEB_BUCKET/ --delete \
  --exclude index.html --exclude config.json \
  --cache-control 'public, max-age=31536000, immutable'

# index.html と config.json は毎回取り直させる
aws s3 cp web/dist/index.html s3://$WEB_BUCKET/index.html \
  --cache-control no-cache --content-type 'text/html; charset=utf-8'
aws s3 cp $WORK/config.json s3://$WEB_BUCKET/config.json \
  --cache-control no-cache --content-type application/json

# CloudFront のキャッシュを消す（初回は不要だが、更新のときは必ず行う）
aws cloudfront create-invalidation --distribution-id $DIST_ID --paths /index.html /config.json
```

- `--exclude` したファイルは、`--delete` でも消されない
- `modes` に `form` を入れるときは、CSP の `form-action` も変える（6.3 の `FormActionSource`、6.4 の `headers.json`）

### 6.7 動作確認

```sh
# SPA とセキュリティヘッダー
curl -sI $WEB_URL/ | grep -iE '^(HTTP|content-type|content-security-policy|strict-transport-security|x-content-type-options|referrer-policy|x-frame-options)'
curl -s $WEB_URL/config.json; echo

# S3 を直接読めないこと（非公開）→ 403
curl -s -o /dev/null -w '%{http_code}\n' https://$WEB_BUCKET.s3.$AWS_REGION.amazonaws.com/index.html

# CORS: SPA のオリジンから発行すると、応答に Access-Control-Allow-Origin が付く
curl -s -o /dev/null -D - -H "Origin: $WEB_URL" -H 'Accept: application/json' \
  -F image=@testdata/images/photo.jpg $API_URL/v1/tickets | grep -iE '^(HTTP|access-control-allow-origin)'
```

ブラウザで `$WEB_URL` を開き、写真を選んで「発行する」を押す。SPA のチケット画面（`#/tickets/{code}?sig=…`）に移り、QR が表示されれば成功。その画面をリロードしても、同じチケットが表示される（再発行されない）。

うまくいかないとき:

| 症状 | 確認すること |
|---|---|
| 「設定を読み込めませんでした」 | `config.json` がアップロードされているか、JSON の形が正しいか（`apiBaseUrl` は `https://` で始まり、末尾に `/` を付けない） |
| 「発行できませんでした」（ブラウザの開発者ツールに CORS のエラー） | 6.5 の CORS 設定。`AllowOrigins` が `$WEB_URL` と完全に一致しているか |
| 開発者ツールに CSP のエラー | CSP の `connect-src` / `img-src` の API のオリジンが `$API_URL` と一致しているか（6.3 の `ApiBaseUrl`、6.4 の `headers.json`） |
| 古い画面のまま | 6.6 の無効化（`create-invalidation`）をしたか |

### 6.8 更新

SPA を変えたときは、6.2 のビルドと 6.6 のアップロード（無効化を含む）を行う。`config.json` だけを変えるときは、6.6 の `config.json` のアップロードと無効化だけでよい。

### 6.9 削除

CloudFormation（6.3）の場合:

```sh
aws s3 rm s3://$WEB_BUCKET --recursive   # バケットが空でないとスタックを削除できない
aws cloudformation delete-stack --stack-name ticketqr-web-$IMPL
aws apigatewayv2 delete-cors-configuration --api-id $API_ID
```

手動（6.4）の場合:

```sh
# ディストリビューションは、無効にしてからでないと削除できない
aws cloudfront get-distribution-config --id $DIST_ID > $WORK/current.json
ETAG=$(jq -r .ETag $WORK/current.json)
jq '.DistributionConfig | .Enabled = false' $WORK/current.json > $WORK/disabled.json
aws cloudfront update-distribution --id $DIST_ID --if-match $ETAG --distribution-config file://$WORK/disabled.json > /dev/null
aws cloudfront wait distribution-deployed --id $DIST_ID
ETAG=$(aws cloudfront get-distribution --id $DIST_ID --query ETag --output text)
aws cloudfront delete-distribution --id $DIST_ID --if-match $ETAG

ETAG=$(aws cloudfront get-response-headers-policy --id $HEADERS_ID --query ETag --output text)
aws cloudfront delete-response-headers-policy --id $HEADERS_ID --if-match $ETAG
ETAG=$(aws cloudfront get-origin-access-control --id $OAC_ID --query ETag --output text)
aws cloudfront delete-origin-access-control --id $OAC_ID --if-match $ETAG

aws s3 rm s3://$WEB_BUCKET --recursive
aws s3api delete-bucket --bucket $WEB_BUCKET
aws apigatewayv2 delete-cors-configuration --api-id $API_ID
```

## 7. 運用メモ

### salt のローテーション

1. パラメータを `{"current":"<新しい salt>","previous":"<今の salt>"}` に更新する（`aws ssm put-parameter --name $SALT_PARAM --type SecureString --overwrite --value file://…`）
2. Lambda は起動したときに salt を読んでキャッシュする。そのため、実行環境を作り直させる必要がある
   - CloudFormation の場合: 新しい `ArtifactPrefix` で再デプロイする
   - 手動の場合: `update-function-configuration` で環境変数を変える
3. 古い URL が不要になったら、`previous` を消す。**sig には期限が無いので、`previous` を消した時点で古い salt で発行したビュー / QR の URL はすべて 403 になる**

### 未対応のもの（今後この手順に追加する）

| 項目 | 状態 |
|---|---|
| `ALLOWED_ORIGINS`（Origin の照合） | 未実装（E2E.md 4.2）。実装したら、Lambda の環境変数を追加する |
| HTTP API の CORS 設定のテンプレート化 | 今は 6.5 の `update-api` で設定する（スタックの外からの変更）。`api.yaml` に `AllowedOrigins` パラメータと `CorsConfiguration` を追加する |
| Web フロントエンドの独自ドメイン | CloudFront の代替ドメイン名と、us-east-1 の ACM 証明書を `web.yaml` に追加する。そのときは CORS の `AllowOrigins` も独自ドメインにする |
| 独自ドメイン | `PublicBaseUrl` パラメータだけ用意してある。ACM 証明書と `AWS::ApiGatewayV2::DomainName`、`ApiMapping` は別途追加する |
| 本物の画像解析サーバーへの接続 | HTTP クライアント（4.7）は Go 版・Node 版とも、仮のプロトコル（analyzer-stub/DESIGN.md 3）で実装済み。本物の仕様が決まったら、レスポンスの解釈部分（Go: `parseResponse`、Node: `parseAnalyzerResponse`）を差し替える。VPC の設定が必要になる可能性がある |
| WAF | HTTP API に直接は付けられない。手前に CloudFront を置く場合に検討する |
| GitHub Actions からのデプロイ | `.github/workflows/st-deploy.yml` を定義済み（未検証）。OIDC で IAM ロールを引き受け、4.3、4.4、6.3、6.5、6.6 を実行する。準備と流れは [CI.md](CI.md) 4章 |
