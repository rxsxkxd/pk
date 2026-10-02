# AWS デプロイ手順

API の設計は [DESIGN.md](DESIGN.md) を参照。デプロイの方法は2つある。

| 方法 | 用途 |
|---|---|
| [手動（AWS CLI）](#3-手動デプロイaws-cli) | 一度試すとき、構成を理解するとき |
| [CloudFormation](#4-cloudformation-デプロイ) | 繰り返しデプロイするとき、環境を複製するとき、CI からデプロイするとき（推奨） |

どちらの方法でも、出来上がる構成は同じになる。

```
API Gateway HTTP API（$default ステージ、自動デプロイ、スロットリング）
 ├─ POST /v1/tickets/qr-inline        → Lambda ticketqr-{impl}-issue-inline
 ├─ POST /v1/tickets                  → Lambda ticketqr-{impl}-issue
 ├─ GET  /v1/tickets/{ticketCode}/view → Lambda ticketqr-{impl}-get-view
 ├─ GET  /v1/tickets/{ticketCode}/qr   → Lambda ticketqr-{impl}-get-qr
 └─ GET  /v1/example/qr                → Lambda ticketqr-{impl}-example-qr
チケット系（上の4つ）: provided.al2023 / arm64 / 256MB、パッケージ ticketqr.zip を共有（どのハンドラを呼ぶかは routeKey で決まる）
                      実行ロールは Secrets Manager の salt だけを読める
example-qr:           provided.al2023 / arm64 / 128MB、別パッケージ exampleqr.zip、設定もシークレットも不要
                      実行ロールはログ出力だけ（チケット系とは別のロール）
Secrets Manager: ticketqr/{impl}/signing-salt（スタックの外で管理する）
```

> 現在の実装の状態: 画像解析は `ANALYZER_MODE=mock`（常に valid を返す）。`ALLOWED_ORIGINS`（Origin の照合と CORS）は未実装（E2E.md 4章）。静的サイトはまだ無いため、この手順の対象は API だけ。

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

`iam:CreateRole` / `PassRole` / `PutRolePolicy` / `AttachRolePolicy`、`lambda:*`、`apigateway:*`（`/apis*`）、`logs:CreateLogGroup` / `PutRetentionPolicy`、`secretsmanager:CreateSecret` / `PutSecretValue`、`s3:PutObject`（CloudFormation の場合は、成果物バケットへの書き込み）、`cloudformation:*`（CloudFormation の場合）。

## 2. 共通の準備

### 2.1 ビルド

```sh
make -C go test
make -C go build
ls go/bin/*.zip   # ticketqr.zip（チケット系4エンドポイント）、exampleqr.zip（example.com の QR）
```

### 2.2 署名用 salt の作成（初回だけ）

salt はスタックの外で作る。理由は2つある。
- スタックを作り直しても salt が変わらないようにするため（salt が変わると、発行済みのビュー / QR の URL がすべて無効になる）
- salt の値がテンプレートやパラメータに出ないようにするため

```sh
umask 077
SALT_FILE=$(mktemp)
printf '{"current":"%s"}' "$(openssl rand -base64 32)" > "$SALT_FILE"

export SECRET_ARN=$(aws secretsmanager create-secret \
  --name ticketqr/$IMPL/signing-salt \
  --description "Ticket QR signing salt ($IMPL)" \
  --secret-string file://"$SALT_FILE" \
  --query ARN --output text)

rm -f "$SALT_FILE"
echo $SECRET_ARN
```

- salt を引数に直接書かない（シェルの履歴やプロセス一覧に残るため）
- 暗号化は既定の `aws/secretsmanager` キーを使う。独自の KMS キーを使う場合は、実行ロールに `kms:Decrypt` を追加する
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
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"$SECRET_ARN\"}]}"

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

### 3.3 Lambda 関数（4つ）

```sh
for f in issue-inline issue get-view get-qr; do
  case $f in issue*) TIMEOUT=15 ;; *) TIMEOUT=5 ;; esac

  aws logs create-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-$f
  aws logs put-retention-policy --log-group-name /aws/lambda/ticketqr-$IMPL-$f --retention-in-days 30

  aws lambda create-function \
    --function-name ticketqr-$IMPL-$f \
    --runtime provided.al2023 --architectures arm64 --handler bootstrap \
    --role $ROLE_ARN --memory-size 256 --timeout $TIMEOUT \
    --zip-file fileb://go/bin/ticketqr.zip \
    --environment "Variables={PUBLIC_BASE_URL=$API_URL,ANALYZER_MODE=mock,SIGNING_SALT_SECRET_ID=$SECRET_ARN,TICKET_SUFFIX_LENGTH=8}" \
    --query FunctionArn --output text
done
```

- 4関数とも同じ zip を使う。関数を分けているのは、タイムアウトと同時実行数をエンドポイントごとに設定するためだけ
- 発行系の関数（`issue-inline`、`issue`）は、画像解析の待ち時間（最大5秒程度）を見込んで 15秒にしている
- 関数を1つにまとめることもできる。コードの変更は不要で、全ルートの統合先を同じ関数にすればよい。ただし、発行系だけの同時実行数の制限はできなくなる
- 画像解析サーバーを守るために同時実行数に上限をかける場合は、次のコマンドを使う: `aws lambda put-function-concurrency --function-name ticketqr-$IMPL-issue --reserved-concurrent-executions 10`

### 3.4 ルート・統合・呼び出し権限

```sh
while read f route; do
  FN_ARN=$(aws lambda get-function --function-name ticketqr-$IMPL-$f --query Configuration.FunctionArn --output text)

  INTEGRATION_ID=$(aws apigatewayv2 create-integration --api-id $API_ID \
    --integration-type AWS_PROXY --integration-uri $FN_ARN \
    --payload-format-version 2.0 --timeout-in-millis 20000 \
    --query IntegrationId --output text)

  aws apigatewayv2 create-route --api-id $API_ID \
    --route-key "$route" --target integrations/$INTEGRATION_ID >/dev/null

  aws lambda add-permission --function-name ticketqr-$IMPL-$f \
    --statement-id apigateway-invoke --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*" >/dev/null
done <<'EOF'
issue-inline POST /v1/tickets/qr-inline
issue POST /v1/tickets
get-view GET /v1/tickets/{ticketCode}/view
get-qr GET /v1/tickets/{ticketCode}/qr
EOF
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
for f in issue-inline issue get-view get-qr; do
  aws lambda update-function-code --function-name ticketqr-$IMPL-$f \
    --zip-file fileb://go/bin/ticketqr.zip --query LastUpdateStatus --output text
done
aws lambda update-function-code --function-name ticketqr-$IMPL-example-qr \
  --zip-file fileb://go/bin/exampleqr.zip --query LastUpdateStatus --output text
```

環境変数を変えるときは `aws lambda update-function-configuration --environment ...` を使う。指定した変数で全体が置き換わるので、既存の変数もすべて指定し直す。

### 3.8 削除

```sh
aws apigatewayv2 delete-api --api-id $API_ID
for f in issue-inline issue get-view get-qr; do
  aws lambda delete-function --function-name ticketqr-$IMPL-$f
  aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-$f
done
aws iam delete-role-policy --role-name ticketqr-$IMPL-lambda --policy-name read-signing-salt
aws iam detach-role-policy --role-name ticketqr-$IMPL-lambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ticketqr-$IMPL-lambda
aws lambda delete-function --function-name ticketqr-$IMPL-example-qr
aws logs delete-log-group --log-group-name /aws/lambda/ticketqr-$IMPL-example-qr
aws iam detach-role-policy --role-name ticketqr-$IMPL-example-lambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name ticketqr-$IMPL-example-lambda
# salt は、必要がなくなったときだけ削除する（2.2 を参照）
```

## 4. CloudFormation デプロイ

テンプレート: [`infra/cloudformation/api.yaml`](infra/cloudformation/api.yaml)（cfn-lint で検証済み）

### 4.1 主なパラメータ

| パラメータ | 既定値 | 内容 |
|---|---|---|
| `Impl` | `go` | `go` / `node`。実装ごとにスタックを分ける |
| `ArtifactBucket` | - | Lambda の zip を置く S3 バケット |
| `ArtifactPrefix` | - | zip のキーの接頭辞。**デプロイのたびに変える**（例: `ticketqr/go/<git sha>`） |
| `SigningSaltSecretArn` | - | 2.2 で作ったシークレットの ARN |
| `AnalyzerMode` | `mock` | 画像解析クライアントの種類 |
| `TicketSuffixLength` | `8` | suffix の桁数 |
| `PublicBaseUrl` | 空 | 独自ドメインを使う場合に指定する。空なら execute-api の URL を自動で使う |
| `ThrottlingRateLimit` / `ThrottlingBurstLimit` | `50` / `100` | 全ルートに共通のスロットリング |
| `IssueReservedConcurrency` | `-1`（設定しない） | 発行系の関数に予約する同時実行数 |
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
for p in ticketqr exampleqr; do
  aws s3 cp go/bin/$p.zip s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX/$p.zip
done
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
    SigningSaltSecretArn=$SECRET_ARN

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

スタックの外にある salt のシークレットと成果物バケットは残る。

## 5. 動作確認

モックの画像解析は、JPEG / PNG のマジックバイトさえあれば通る。

```sh
printf '\xff\xd8\xff\xe0test' > /tmp/sample.jpg

# パターンA → 201 JSON
curl -s -F image=@/tmp/sample.jpg $API_URL/v1/tickets/qr-inline | head -c 200; echo

# パターンB-1 → 303 とビューの URL
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -F image=@/tmp/sample.jpg $API_URL/v1/tickets); echo $LOC

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
aws logs tail /aws/lambda/ticketqr-$IMPL-issue --follow
aws logs tail /aws/apigateway/ticketqr-$IMPL --since 10m   # CloudFormation の場合だけ（アクセスログ）
```

## 6. 運用メモ

### salt のローテーション

1. シークレットを `{"current":"<新しい salt>","previous":"<今の salt>"}` に更新する（`aws secretsmanager put-secret-value`）
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
| 本物の画像解析クライアント | プロトコルが決まり次第追加する。認証情報のシークレットと VPC の設定が必要になる可能性がある |
| WAF | HTTP API に直接は付けられない。手前に CloudFront を置く場合に検討する |
| GitHub Actions からのデプロイ | OIDC で IAM ロールを引き受けて、4.3〜4.4 を実行する形を想定 |
