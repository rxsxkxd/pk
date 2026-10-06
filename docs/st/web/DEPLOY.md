# Web フロントエンドのデプロイ手順（S3 + CloudFront）

SPA（`web/`。[DESIGN.md](DESIGN.md)）を、非公開の S3 バケットに置き、CloudFront（OAC）経由で配信する。API とは**別のスタック・別のテンプレート**（`infra/cloudformation/web.yaml`）にする。

全体の構成と共通の準備は [../DEPLOY.md](../DEPLOY.md)、API のデプロイは [../go/DEPLOY.md](../go/DEPLOY.md) / [../node/DEPLOY.md](../node/DEPLOY.md)。GitHub Actions からのデプロイは [../CI.md](../CI.md) 4章。

> **提案中**: `web.yaml` を S3 のバケット（`web-bucket.yaml`）と CloudFront（`edge.yaml`）に分け、テスト環境は CloudFront なし、本番は SPA と API を1つの CloudFront にまとめる案がある（[../notes/cloudfront-split.md](../notes/cloudfront-split.md)）。採用したら、この手順書を構成ごとに書き直す。

```
利用者のブラウザ ──HTTPS──▶ CloudFront（既定のルートオブジェクト index.html、セキュリティヘッダー）
                              └─ OAC ──▶ S3 バケット（非公開。index.html、assets/*、config.json）
SPA の JS ──fetch / <img>──▶ チケット API（../go/DEPLOY.md か ../node/DEPLOY.md で作った HTTP API。CORS で SPA のオリジンを許可する）
```

| 項目 | 内容 |
|---|---|
| スタック名 | `ticketqr-web-$IMPL`（どちらの実装の API を使うかで分ける。SPA 自体は同じビルド） |
| S3 バケット | 非公開（パブリックアクセスはすべてブロック）。CloudFront の OAC だけが読める |
| CloudFront | HTTPS へリダイレクト、既定のルートオブジェクト `index.html`（hash モードのルーティングなので、ほかのパスを `index.html` に向ける設定は不要）、マネージドのキャッシュポリシー CachingOptimized |
| セキュリティヘッダー | Response Headers Policy で CSP・HSTS・`X-Content-Type-Options`・`Referrer-Policy: no-referrer`・`X-Frame-Options: DENY` を付ける（DESIGN.md 9章） |
| `config.json` | 環境ごとに作ってアップロードする（ビルドには埋め込まない）。API の URL と、使う発行方式（`modes`）を書く |

## 1. 前提

- チケット API をデプロイ済みで、`$API_URL` が分かっていること（[../go/DEPLOY.md](../go/DEPLOY.md) または [../node/DEPLOY.md](../node/DEPLOY.md)）
- 作業ディレクトリは `docs/st`。`AWS_REGION`・`ACCOUNT_ID`・`IMPL`（使う API の実装。`go` / `node`）を設定しておく（../DEPLOY.md 1章）
- Node.js 24（SPA のビルド）、手動で削除する場合は `jq`
- デプロイする人の権限: ../DEPLOY.md 1章のものに加えて、`s3:CreateBucket` / `PutBucketPolicy` / `PutObject` / `DeleteObject` / `ListBucket`、`cloudfront:*`（ディストリビューション、OAC、Response Headers Policy、無効化）

```sh
echo $API_URL   # https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com（末尾の / は付けない）
export WORK=$(mktemp -d)   # 設定ファイルなどの一時置き場
```

## 2. ビルド

```sh
npm --prefix web ci
npm --prefix web test
npm --prefix web run build      # 型チェック（vue-tsc）とビルド → web/dist/
ls web/dist                     # index.html、assets/、config.json（ローカル開発用。アップロードしない）
```

`web/dist/config.json` は開発用の値（`apiBaseUrl` が空）なので、アップロードしない。環境ごとの `config.json` は 6章で作る。

## 3. S3 と CloudFront の作成: CloudFormation（推奨）

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
| `ApiBaseUrl` | - | チケット API のオリジン（`$API_URL`）。CSP の `img-src` と `connect-src` に入る（`connect-src` には、SPA が自分のオリジンから `config.json` を `fetch` するための `'self'` も入る） |
| `FormActionSource` | `'none'` | CSP の `form-action`。フォーム送信方式（`modes` の `form`）を有効にする環境だけ、`$API_URL` にする |
| `PriceClass` | `PriceClass_200` | CloudFront の配信地域（日本を含む） |

- CloudFront のディストリビューションの作成には、数分〜十数分かかる
- API の URL が変わったら、`ApiBaseUrl` を変えて同じコマンドを実行する（CSP が更新される）。`config.json` も作り直す（6章）

## 4. S3 と CloudFront の作成: 手動（AWS CLI）

CloudFormation を使わない場合。3章と同じ構成を作る。

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
      "ContentSecurityPolicy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: $API_URL; connect-src 'self' $API_URL; form-action 'none'; frame-ancestors 'none'",
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

## 5. チケット API の CORS 設定

SPA（`$WEB_URL`）と API（`$API_URL`）はオリジンが違う。SPA が発行の応答（JSON）を読めるように、**API Gateway の CORS 設定で SPA のオリジンを許可する**（../E2E.md 4.3）。これがないと、メインの画面遷移方式が動かない。

```sh
# 手動で作った API: $API_ID は、各実装の DEPLOY.md 5.2 で取得したもの
# CloudFormation で作った API: 名前から API の ID を調べる
export API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='ticketqr-$IMPL'].ApiId | [0]" --output text)

aws apigatewayv2 update-api --api-id $API_ID \
  --cors-configuration "{\"AllowOrigins\":[\"$WEB_URL\"],\"AllowMethods\":[\"GET\",\"POST\"],\"MaxAge\":300}" \
  --query CorsConfiguration
```

- `fetch` の `FormData` 送信は単純リクエストなので、`AllowHeaders` は不要
- **CloudFormation で作った API の注意**: `api.yaml` にはまだ CORS の設定がない（../DEPLOY.md 4章「まだ対応していないもの」）。上のコマンドはスタックの外からの変更になる。`api.yaml` に `AllowedOrigins` パラメータと `CorsConfiguration` を追加するまでの暫定の手順で、API のスタックを更新したあとに CORS が残っているかを確認する（`aws apigatewayv2 get-api --api-id $API_ID --query CorsConfiguration`）
- CORS が止めるのは、応答を JS から読むことだけ。ほかのサイトからの発行を止める Origin の照合（`ALLOWED_ORIGINS`）は未実装（../E2E.md 4.2）

## 6. config.json の作成とアップロード

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
- `modes` に `form` を入れるときは、CSP の `form-action` も変える（3章の `FormActionSource`、4章の `headers.json`）

## 7. 動作確認

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
| 「発行できませんでした」（ブラウザの開発者ツールに CORS のエラー） | 5章の CORS 設定。`AllowOrigins` が `$WEB_URL` と完全に一致しているか |
| 開発者ツールに CSP のエラー | CSP の `connect-src` / `img-src` の API のオリジンが `$API_URL` と一致しているか（3章の `ApiBaseUrl`、4章の `headers.json`）。`config.json` が読めないときは、`connect-src` に `'self'` があるか |
| 古い画面のまま | 6章の無効化（`create-invalidation`）をしたか |

## 8. 更新

SPA を変えたときは、2章のビルドと 6章のアップロード（無効化を含む）を行う。`config.json` だけを変えるときは、6章の `config.json` のアップロードと無効化だけでよい。

セキュリティヘッダー（CSP など）を変えたとき（例: `connect-src` に `'self'` を足したとき）:

```sh
# CloudFormation（3章）の場合: 同じコマンドをもう一度実行する（Response Headers Policy だけが更新される）
aws cloudformation deploy \
  --stack-name ticketqr-web-$IMPL \
  --template-file infra/cloudformation/web.yaml \
  --parameter-overrides \
    ApiBaseUrl=$API_URL

# 手動（4章）の場合: headers.json を直してから、ETag を付けて更新する
ETAG=$(aws cloudfront get-response-headers-policy --id $HEADERS_ID --query ETag --output text)
aws cloudfront update-response-headers-policy --id $HEADERS_ID --if-match $ETAG \
  --response-headers-policy-config file://$WORK/headers.json

# 反映を待って、ヘッダーを確かめる
aws cloudfront wait distribution-deployed --id $DIST_ID
curl -sI $WEB_URL/ | grep -i '^content-security-policy'
```

- ヘッダーは CloudFront が応答のたびに付けるので、キャッシュの無効化は要らない（ディストリビューションへの反映を待つだけ）

## 9. 削除

CloudFormation（3章）の場合:

```sh
aws s3 rm s3://$WEB_BUCKET --recursive   # バケットが空でないとスタックを削除できない
aws cloudformation delete-stack --stack-name ticketqr-web-$IMPL
aws apigatewayv2 delete-cors-configuration --api-id $API_ID
```

手動（4章）の場合:

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
