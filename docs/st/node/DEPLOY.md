# Node 版 API のデプロイ手順

チケット QR API の **Node 版**（`node/`）を AWS にデプロイする手順。Go 版は [../go/DEPLOY.md](../go/DEPLOY.md)、全体の構成と共通の準備は [../DEPLOY.md](../DEPLOY.md)、Web フロントエンドは [../web/DEPLOY.md](../web/DEPLOY.md)。実装の詳細は [../NODE.md](../NODE.md)。

```
API Gateway HTTP API ticketqr-node（$default ステージ、自動デプロイ、スロットリング）
 ├─ POST /v1/tickets/qr-inline        ┐  QR 同梱発行 API
 ├─ POST /v1/tickets                  ├→ Lambda ticketqr-node-tickets  チケット発行 API
 ├─ GET  /v1/tickets/{ticketCode}/view ┘                                   チケット表示ページ
 └─ GET  /v1/tickets/{ticketCode}/qr   → Lambda ticketqr-node-get-qr   QR 画像 API
API Gateway HTTP API ticketqr-node-example（7章。チケット API とは無関係）
 └─ GET  /v1/example/qr                → Lambda ticketqr-node-example-qr
Parameter Store（SecureString）: /ticketqr/node/signing-salt（スタックの外で管理する。3章）
```

| 項目 | 内容 |
|---|---|
| ランタイム | nodejs24.x / arm64。zip の中身は esbuild でまとめた `index.mjs` だけ（`@aws-sdk/*` は Lambda のランタイムのものを使う） |
| パッケージ | `node/dist/ticketqr.zip`（チケット系の2関数で共有。どのハンドラーを呼ぶかは `routeKey` で決まる）、`node/dist/exampleqr.zip`（example.com の QR） |
| スタック | `ticketqr-node`（`infra/cloudformation/api.yaml`）、`ticketqr-node-example`（`infra/cloudformation/example.yaml`） |
| 方法 | CloudFormation（4章。推奨）か、手動の AWS CLI（5章）。どちらでも同じ構成になる |

## 1. 前提

- [../DEPLOY.md](../DEPLOY.md) の 1章（AWS CLI と環境変数）と 2章（成果物バケット。CloudFormation の場合）を済ませておく
- Node.js 24、`npm`、`zip`、`openssl`
- 作業ディレクトリは `docs/st`（テンプレートとテスト画像を相対パスで参照するため）

```sh
cd docs/st
export AWS_REGION=ap-northeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export IMPL=node
export SALT_PARAM=/ticketqr/$IMPL/signing-salt
```

## 2. ビルド

```sh
npm --prefix node ci
npm --prefix node run typecheck
npm --prefix node test
npm --prefix node run build
ls node/dist/*.zip   # ticketqr.zip（チケット系4エンドポイント）、exampleqr.zip（example.com の QR）
```

## 3. 署名用 salt の作成（初回だけ）

salt はスタックの外で作る。理由は2つある。
- スタックを作り直しても salt が変わらないようにするため（salt が変わると、発行済みのチケット表示ページ / QR 画像の URL がすべて無効になる）
- salt の値がテンプレートやパラメータに出ないようにするため

```sh
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
- Go 版とは別のパラメータにする（スタックごとに URL が別になるため、同じ salt を使う必要はない）

## 4. CloudFormation デプロイ（推奨）

### 4.1 主なパラメータ（`api.yaml`）

| パラメータ | 既定値 | 内容 |
|---|---|---|
| `Impl` | `go` | **`node`** を指定する。Runtime と Handler はテンプレートの `ImplMap` が切り替える（`nodejs24.x` / `index.handler`） |
| `ArtifactBucket` | - | Lambda の zip を置く S3 バケット（../DEPLOY.md 2章） |
| `ArtifactPrefix` | - | zip のキーの接頭辞。**デプロイのたびに変える**（例: `ticketqr/node/<git sha>`） |
| `SigningSaltParameterName` | - | 3章で作った salt のパラメータ名（`/ticketqr/node/signing-salt`） |
| `AnalyzerMode` | `mock` | 画像解析クライアントの種類。`mock`（プロセス内で常に valid）/ `http`（`AnalyzerUrl` に POST）。6章 |
| `AnalyzerUrl` | 空 | `AnalyzerMode=http` のときの POST 先 |
| `AnalyzerApiKeyParameterName` | 空 | `AnalyzerMode=http` のときの API キーのパラメータ名。指定すると、Lambda の実行ロールに読み取り権限が付く |
| `TicketSuffixLength` | `8` | suffix の桁数 |
| `PublicBaseUrl` | 空 | 独自ドメインを使う場合に指定する。空なら execute-api の URL を自動で使う |
| `ThrottlingRateLimit` / `ThrottlingBurstLimit` | `50` / `100` | 全ルートに共通のスロットリング |
| `IssueReservedConcurrency` | `-1`（設定しない） | `tickets` 関数に予約する同時実行数（画像解析サーバーの保護用） |
| `LogRetentionDays` | `30` | Lambda と API のアクセスログの保持日数 |

### 4.2 zip のアップロード

```sh
export ARTIFACT_BUCKET=ticketqr-artifacts-$ACCOUNT_ID-$AWS_REGION   # ../DEPLOY.md 2章で作ったもの
npm --prefix node run build
export ARTIFACT_PREFIX=ticketqr/$IMPL/$(git rev-parse --short HEAD)$(git diff --quiet || echo -dirty-$(date +%s))
aws s3 cp node/dist/ticketqr.zip s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX/ticketqr.zip
aws s3 cp node/dist/exampleqr.zip s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX/exampleqr.zip
```

CloudFormation は、`S3Key` が変わらない限り Lambda のコードを更新しない。そのため、デプロイのたびに接頭辞を変える。コミットしていない変更がある場合は、接頭辞に `-dirty-<時刻>` を付ける。

### 4.3 スタックのデプロイ（作成と更新は同じコマンド）

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
- `$API_URL` は、Web フロントエンドのデプロイ（../web/DEPLOY.md）でも使う

### 4.4 ロールバック

以前の `ARTIFACT_PREFIX` を指定して、4.3 をもう一度実行する（S3 上の古い zip は消さずに残しておく）。

### 4.5 削除

```sh
aws cloudformation delete-stack --stack-name ticketqr-$IMPL
aws cloudformation wait stack-delete-complete --stack-name ticketqr-$IMPL
```

スタックの外にある salt のパラメータと成果物バケットは残る。

## 5. 手動デプロイ（AWS CLI）

CloudFormation を使わない場合。一度試すときや、構成を理解するときに使う。

### 5.1 Lambda の実行ロール

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

### 5.2 HTTP API の作成（先に URL を決める）

Lambda の環境変数 `PUBLIC_BASE_URL` に API の URL が必要なので、API を先に作る。

```sh
read API_ID API_URL < <(aws apigatewayv2 create-api \
  --name ticketqr-$IMPL --protocol-type HTTP \
  --query '[ApiId,ApiEndpoint]' --output text)
export API_ID API_URL
echo $API_URL   # https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com
```

### 5.3 Lambda 関数（チケット系は2つ）

| 関数 | 担当ルート | タイムアウト |
|---|---|---|
| `ticketqr-$IMPL-tickets` | QR 同梱発行 API、チケット発行 API、チケット表示ページ（画像解析・採番・HTML） | 15秒 |
| `ticketqr-$IMPL-get-qr` | QR 画像 API（QR 画像の生成） | 5秒 |

```sh
aws logs create-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-tickets
aws logs put-retention-policy --log-group-name /aws/lambda/ticketqr-$IMPL-tickets --retention-in-days 30
aws lambda create-function \
  --function-name ticketqr-$IMPL-tickets \
  --runtime nodejs24.x --architectures arm64 --handler index.handler \
  --role $ROLE_ARN --memory-size 256 --timeout 15 \
  --zip-file fileb://node/dist/ticketqr.zip \
  --environment "Variables={PUBLIC_BASE_URL=$API_URL,ANALYZER_MODE=mock,SIGNING_SALT_PARAMETER_NAME=$SALT_PARAM,TICKET_SUFFIX_LENGTH=8}" \
  --query FunctionArn --output text

aws logs create-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-get-qr
aws logs put-retention-policy --log-group-name /aws/lambda/ticketqr-$IMPL-get-qr --retention-in-days 30
aws lambda create-function \
  --function-name ticketqr-$IMPL-get-qr \
  --runtime nodejs24.x --architectures arm64 --handler index.handler \
  --role $ROLE_ARN --memory-size 256 --timeout 5 \
  --zip-file fileb://node/dist/ticketqr.zip \
  --environment "Variables={PUBLIC_BASE_URL=$API_URL,ANALYZER_MODE=mock,SIGNING_SALT_PARAMETER_NAME=$SALT_PARAM,TICKET_SUFFIX_LENGTH=8}" \
  --query FunctionArn --output text
```

- 2関数とも同じ zip（`ticketqr.zip`）を使う。どのハンドラーを呼ぶかは、イベントの `routeKey` で決まる（コードは関数の分け方に依存しない）
- `tickets` は、画像解析の待ち時間（最大5秒程度）を見込んで 15秒にしている。チケット表示ページも同じ関数なので 15秒になるが、実際の処理は数ミリ秒で終わる
- `get-qr` を分けているのは、ブラウザの `<img>` から呼ばれる QR 生成を、画像解析の同時実行数の上限から切り離すため
- 画像解析サーバーを守るために同時実行数に上限をかける場合は、次のコマンドを使う: `aws lambda put-function-concurrency --function-name ticketqr-$IMPL-tickets --reserved-concurrent-executions 10`（チケット表示ページもこの上限の対象に入る）

### 5.4 ルート・統合・呼び出し権限

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

### 5.5 ステージ（スロットリングを含む）

```sh
aws apigatewayv2 create-stage --api-id $API_ID --stage-name '$default' --auto-deploy \
  --default-route-settings ThrottlingRateLimit=50,ThrottlingBurstLimit=100
```

この時点で API が公開される。動作確認は [8章](#8-動作確認)。

### 5.6 コードの更新

```sh
npm --prefix node run build
aws lambda update-function-code --function-name ticketqr-$IMPL-tickets \
  --zip-file fileb://node/dist/ticketqr.zip --query LastUpdateStatus --output text
aws lambda update-function-code --function-name ticketqr-$IMPL-get-qr \
  --zip-file fileb://node/dist/ticketqr.zip --query LastUpdateStatus --output text
```

環境変数を変えるときは `aws lambda update-function-configuration --environment ...` を使う。指定した変数で全体が置き換わるので、既存の変数もすべて指定し直す。

### 5.7 削除

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

## 6. 画像解析サーバーの切り替え（ANALYZER_MODE）

| モード | 動き | 必要なパラメータ |
|---|---|---|
| `mock`（既定） | API の中で、通信せずに常に valid を返す | なし |
| `http` | `AnalyzerUrl` に画像をそのまま POST する（`application/octet-stream`、`x-api-key` 付き。1回5秒でタイムアウトし、5xx・タイムアウト・通信エラーのときだけ1回リトライ） | `AnalyzerUrl`、`AnalyzerApiKeyParameterName` |

本物の画像解析サーバーができるまでは、`http` の接続先に画像解析サーバーのスタブを使う。**スタブと API キーの用意は Node 版・Go 版で共通**なので、[../DEPLOY.md](../DEPLOY.md) 3章で行い、`ANALYZER_URL`・`ANALYZER_KEY_PARAM`・`STUB_IMPL` を設定しておく。

### 6.1 CloudFormation の場合

4.2 で zip をアップロードしたうえで、4.3 のコマンドにパラメータを3つ足す。

```sh
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
- `mock` に戻すときは、4.3 のコマンドを `AnalyzerMode` などを付けずに実行する（既定値の `mock` に戻る）

### 6.2 手動デプロイ（5章）の場合

5.1 の実行ロールに API キーの読み取り権限を足し、2つの Lambda の環境変数に `ANALYZER_MODE=http`、`ANALYZER_URL`、`ANALYZER_API_KEY_PARAMETER_NAME` を加える。

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

### 6.3 動作確認

```sh
curl -s -F image=@testdata/images/photo.jpg $API_URL/v1/tickets/qr-inline | head -c 120; echo   # 201（スタブ経由で valid）

# スタブが受け取った画像のハッシュが、送ったファイルと一致することを確認する（画像が加工されずに届いている）
shasum -a 256 testdata/images/photo.jpg
aws logs tail /aws/lambda/ticketqr-analyzer-stub-$STUB_IMPL --since 5m | grep '"msg":"analyzed"'

# スタブにつながらない・API キーが合わないときは、API が 502 ANALYSIS_UPSTREAM_ERROR を返し、ログに原因が出る
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 5m | grep 'image analysis failed'
```

API を `http` のままスタブを削除すると、発行（QR 同梱発行 API・チケット発行 API）がすべて 502 になる。スタブを削除する前に `mock` に戻す。

## 7. example.com の QR エンドポイント（別スタック・別 API）

`GET /v1/example/qr` は、チケット API とは無関係なエンドポイント。パッケージ（`exampleqr.zip`）、テンプレート（`example.yaml`）、HTTP API、実行ロールをすべて分け、チケット API とは独立して作成・削除できるようにする。設定もシークレットも使わないので、実行ロールはログ出力だけ。

### 7.1 CloudFormation

`exampleqr.zip` は 4.2 でチケット API の zip と一緒にアップロードしてある。

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
| `Impl` / `ArtifactBucket` / `ArtifactPrefix` | - | 4.1 と同じ（`Impl=node`） |
| `ThrottlingRateLimit` / `ThrottlingBurstLimit` | `10` / `20` | example 用の HTTP API のスロットリング |
| `LogRetentionDays` | `30` | ログの保持日数 |

### 7.2 手動（AWS CLI）

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
  --runtime nodejs24.x --architectures arm64 --handler index.handler \
  --role $EXAMPLE_ROLE_ARN --memory-size 128 --timeout 5 \
  --zip-file fileb://node/dist/exampleqr.zip \
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
  --zip-file fileb://node/dist/exampleqr.zip --query LastUpdateStatus --output text

# 削除
aws apigatewayv2 delete-api --api-id $EXAMPLE_API_ID
aws lambda delete-function --function-name ticketqr-$IMPL-example-qr
aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-example-qr
aws iam detach-role-policy --role-name ticketqr-$IMPL-example-lambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ticketqr-$IMPL-example-lambda
```

## 8. 動作確認

動作確認には `testdata/images/` の小さな画像（JPEG / PNG / HEIC / HEIF / AVIF / WebP。各32×32）を使う。画像の形式は API がファイルの中身で判定するので（先頭数バイトだけの偽の画像は 415 になる）、手元の写真を使ってもよい。

```sh
# QR 同梱発行 API → 201 JSON
curl -s -F image=@testdata/images/photo.jpg $API_URL/v1/tickets/qr-inline | head -c 200; echo

# チケット発行 API（フォーム送信） → 303 とチケット表示ページの URL
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -F image=@testdata/images/photo.jpg $API_URL/v1/tickets); echo $LOC

# チケット発行 API（Accept: application/json） → 201 JSON
curl -s -H 'Accept: application/json' -F image=@testdata/images/photo.jpg $API_URL/v1/tickets; echo

# チケット表示ページ → 200 HTML、QR 画像 API → 200 image/png
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' "$LOC"
QR=$(echo "$LOC" | sed 's#/view?#/qr?#')
curl -s -o /tmp/qr.png -w '%{http_code} %{content_type}\n' "$QR"

# 署名を改ざん → 403
curl -s -o /dev/null -w '%{http_code}\n' "${LOC%sig=*}sig=AAAAAAAAAAAAAAAAAAAAAA"

# example.com の QR → 200 image/png（7章の別 API）
curl -s -o /tmp/example.png -w '%{http_code} %{content_type}\n' $EXAMPLE_URL
```

ブラウザで `$LOC` を開くと、チケット表示ページ（QR の画面）が表示される。

ログを見る:

```sh
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --follow
aws logs tail /aws/apigateway/ticketqr-$IMPL --since 10m   # CloudFormation の場合だけ（アクセスログ）
```

写真を受け取る2つの API のログには、ブラウザと OS の情報（`client`。User-Agent などを加工せずに記録）が付く。OS・ブラウザごとに集計するには、後処理のサンプルのスクリプトを使う（../DESIGN.md 10章「ブラウザと OS の記録」）:

```sh
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 1d --filter-pattern '"request completed"' \
  | python3 scripts/client_log_summary.py
```

次は Web フロントエンド（SPA）のデプロイ: [../web/DEPLOY.md](../web/DEPLOY.md)（`$API_URL` を使う）。

## 9. 運用

### salt のローテーション

1. パラメータを `{"current":"<新しい salt>","previous":"<今の salt>"}` に更新する（`aws ssm put-parameter --name $SALT_PARAM --type SecureString --overwrite --value file://…`）
2. Lambda は起動したときに salt を読んでキャッシュする。そのため、実行環境を作り直させる必要がある
   - CloudFormation の場合: 新しい `ARTIFACT_PREFIX` で再デプロイする（4.2、4.3）
   - 手動の場合: `update-function-configuration` で環境変数を変える
3. 古い URL が不要になったら、`previous` を消す。**sig には期限が無いので、`previous` を消した時点で古い salt で発行したチケット表示ページ / QR 画像の URL はすべて 403 になる**

まだ対応していないもの（CORS のテンプレート化、Origin の照合、独自ドメインなど）は [../DEPLOY.md](../DEPLOY.md) 4章。
