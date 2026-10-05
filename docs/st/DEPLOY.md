# AWS デプロイ手順

API の設計は [DESIGN.md](DESIGN.md) を参照。デプロイの方法は2つある。

| 方法 | 用途 |
|---|---|
| [手動（AWS CLI）](#3-手動デプロイaws-cli) | 一度試すとき、構成を理解するとき |
| [CloudFormation](#4-cloudformation-デプロイ) | 繰り返しデプロイするとき、環境を複製するとき、CI からデプロイするとき（推奨） |

どちらの方法でも、出来上がる構成は同じになる。

```
API Gateway HTTP API（$default ステージ、自動デプロイ、スロットリング）
 ├─ POST /v1/tickets/qr-inline        ┐
 ├─ POST /v1/tickets                  ├→ Lambda ticketqr-{impl}-tickets（画像解析・採番・ビュー）
 ├─ GET  /v1/tickets/{ticketCode}/view ┘
 ├─ GET  /v1/tickets/{ticketCode}/qr   → Lambda ticketqr-{impl}-get-qr（QR 画像の生成）
 └─ GET  /v1/example/qr                → Lambda ticketqr-{impl}-example-qr
チケット系（上の2関数）: provided.al2023 / arm64 / 256MB、パッケージ ticketqr.zip を共有（どのハンドラを呼ぶかは routeKey で決まる）
                      実行ロールは Parameter Store の salt（と、http モードのときは解析サーバーの API キー）だけを読める
example-qr:           provided.al2023 / arm64 / 128MB、別パッケージ exampleqr.zip、設定もシークレットも不要
                      実行ロールはログ出力だけ（チケット系とは別のロール）
Parameter Store（SecureString）: /ticketqr/{impl}/signing-salt（スタックの外で管理する）
```

> 現在の実装の状態: Go 版・Node 版とも実装済み（同じ手順でデプロイできる。2.1.1）。画像解析は `ANALYZER_MODE=mock`（プロセス内で常に valid）と `ANALYZER_MODE=http`（画像解析サーバーに POST。Node 版のみ）から選ぶ（[4.7](#47-画像解析サーバーの切り替えanalyzer_mode)）。`ALLOWED_ORIGINS`（Origin の照合と CORS）は未実装（E2E.md 4章）。静的サイトはまだ無いため、この手順の対象は API だけ。

## 1. 前提

- AWS CLI v2 と、デプロイ先アカウントの認証情報
- Go（`docs/st/go.mod` のバージョン）、`make`、`zip`、`openssl`
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
| 手動デプロイ（3.3、3.6）の `--runtime` / `--handler` | `provided.al2023` / `bootstrap` | `nodejs24.x` / `index.handler` |
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

### 3.6 example.com の QR エンドポイント（別パッケージ）

salt を読まないので、ログ出力の権限だけを持つ実行ロールを別に作る。

```sh
EXAMPLE_ROLE_NAME=ticketqr-$IMPL-example-lambda
aws iam create-role --role-name $EXAMPLE_ROLE_NAME \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name $EXAMPLE_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
EXAMPLE_ROLE_ARN=$(aws iam get-role --role-name $EXAMPLE_ROLE_NAME --query Role.Arn --output text)
sleep 10

aws logs create-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-example-qr
aws logs put-retention-policy --log-group-name /aws/lambda/ticketqr-$IMPL-example-qr --retention-in-days 30

FN_ARN=$(aws lambda create-function \
  --function-name ticketqr-$IMPL-example-qr \
  --runtime provided.al2023 --architectures arm64 --handler bootstrap \
  --role $EXAMPLE_ROLE_ARN --memory-size 128 --timeout 5 \
  --zip-file fileb://go/bin/exampleqr.zip \
  --query FunctionArn --output text)

INTEGRATION_ID=$(aws apigatewayv2 create-integration --api-id $API_ID \
  --integration-type AWS_PROXY --integration-uri $FN_ARN \
  --payload-format-version 2.0 --timeout-in-millis 10000 \
  --query IntegrationId --output text)
aws apigatewayv2 create-route --api-id $API_ID \
  --route-key 'GET /v1/example/qr' --target integrations/$INTEGRATION_ID >/dev/null
aws lambda add-permission --function-name ticketqr-$IMPL-example-qr \
  --statement-id apigateway-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*" >/dev/null
```

ステージは自動デプロイなので、ルートを追加するとすぐに公開される。

### 3.7 コードの更新

```sh
make -C go build
aws lambda update-function-code --function-name ticketqr-$IMPL-tickets \
  --zip-file fileb://go/bin/ticketqr.zip --query LastUpdateStatus --output text
aws lambda update-function-code --function-name ticketqr-$IMPL-get-qr \
  --zip-file fileb://go/bin/ticketqr.zip --query LastUpdateStatus --output text
aws lambda update-function-code --function-name ticketqr-$IMPL-example-qr \
  --zip-file fileb://go/bin/exampleqr.zip --query LastUpdateStatus --output text
```

環境変数を変えるときは `aws lambda update-function-configuration --environment ...` を使う。指定した変数で全体が置き換わるので、既存の変数もすべて指定し直す。

### 3.8 削除

```sh
aws apigatewayv2 delete-api --api-id $API_ID
aws lambda delete-function --function-name ticketqr-$IMPL-tickets
aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-tickets
aws lambda delete-function --function-name ticketqr-$IMPL-get-qr
aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-get-qr
aws iam delete-role-policy --role-name ticketqr-$IMPL-lambda --policy-name read-signing-salt
aws iam detach-role-policy --role-name ticketqr-$IMPL-lambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ticketqr-$IMPL-lambda
aws lambda delete-function --function-name ticketqr-$IMPL-example-qr
aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-example-qr
aws iam detach-role-policy --role-name ticketqr-$IMPL-example-lambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ticketqr-$IMPL-example-lambda
# salt のパラメータは、必要がなくなったときだけ削除する（aws ssm delete-parameter --name $SALT_PARAM）
```

## 4. CloudFormation デプロイ

テンプレート: [`infra/cloudformation/api.yaml`](infra/cloudformation/api.yaml)（cfn-lint で検証済み）

### 4.1 主なパラメータ

| パラメータ | 既定値 | 内容 |
|---|---|---|
| `Impl` | `go` | `go` / `node`。実装ごとにスタックを分ける |
| `ArtifactBucket` | - | Lambda の zip を置く S3 バケット |
| `ArtifactPrefix` | - | zip のキーの接頭辞。**デプロイのたびに変える**（例: `ticketqr/go/<git sha>`） |
| `SigningSaltParameterName` | - | 2.2 で作った salt のパラメータ名（例: `/ticketqr/go/signing-salt`） |
| `AnalyzerMode` | `mock` | 画像解析クライアントの種類。`mock`（プロセス内で常に valid）/ `http`（`AnalyzerUrl` に POST。**Node 版のみ対応**）。4.7 |
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
| `http` | `AnalyzerUrl` に画像をそのまま POST する（`application/octet-stream`、`x-api-key` 付き。1回5秒でタイムアウトし、5xx・タイムアウト・通信エラーのときだけ1回リトライ） | `AnalyzerUrl`、`AnalyzerApiKeyParameterName` | **Node 版のみ**（Go 版で `http` を指定すると、Lambda の初期化でエラーになる） |

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

#### 手順3: API を `http` モードでデプロイする（Node 版）

4.3 で Node 版の zip（`node/dist/*.zip`）をアップロードしたうえで、4.4 のコマンドにパラメータを3つ足す。

```sh
export IMPL=node
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
curl -s -o /tmp/example.png -w '%{http_code} %{content_type}\n' $API_URL/v1/example/qr
```

ブラウザで `$LOC` を開くと、QR の画面が表示される。

ログを見る:

```sh
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --follow
aws logs tail /aws/apigateway/ticketqr-$IMPL --since 10m   # CloudFormation の場合だけ（アクセスログ）
```

## 6. 運用メモ

### salt のローテーション

1. パラメータを `{"current":"<新しい salt>","previous":"<今の salt>"}` に更新する（`aws ssm put-parameter --name $SALT_PARAM --type SecureString --overwrite --value file://…`）
2. Lambda は起動したときに salt を読んでキャッシュする。そのため、実行環境を作り直させる必要がある
   - CloudFormation の場合: 新しい `ArtifactPrefix` で再デプロイする
   - 手動の場合: `update-function-configuration` で環境変数を変える
3. 古い URL が不要になったら、`previous` を消す。**sig には期限が無いので、`previous` を消した時点で古い salt で発行したビュー / QR の URL はすべて 403 になる**

### 未対応のもの（今後この手順に追加する）

| 項目 | 状態 |
|---|---|
| `ALLOWED_ORIGINS`（Origin の照合）と、HTTP API の CORS 設定 | 未実装（E2E.md 4章）。実装したら、テンプレートの `CorsConfiguration` と環境変数を追加する |
| 静的サイト（S3 + CloudFront） | 未作成（E2E.md 3章） |
| 独自ドメイン | `PublicBaseUrl` パラメータだけ用意してある。ACM 証明書と `AWS::ApiGatewayV2::DomainName`、`ApiMapping` は別途追加する |
| 本物の画像解析サーバーへの接続 | Node 版の HTTP クライアント（4.7）は仮のプロトコル（analyzer-stub/DESIGN.md 3）で実装済み。本物の仕様が決まったらレスポンスの解釈部分を差し替える。VPC の設定が必要になる可能性がある。Go 版の HTTP クライアントは未実装 |
| WAF | HTTP API に直接は付けられない。手前に CloudFront を置く場合に検討する |
| GitHub Actions からのデプロイ | OIDC で IAM ロールを引き受けて、4.3〜4.4 を実行する形を想定 |
