# Web フロントエンドのデプロイ手順（S3 + CloudFront。直結・統合の2構成）

SPA（`web/`。[DESIGN.md](DESIGN.md)）を、非公開の S3 バケットに置き、CloudFront（OAC）経由で配信する。API とは**別のスタック・別のテンプレート**（`infra/cloudformation/web.yaml`）にする。

API（チケット発行・QR 生成）への経路は、環境ごとに次の2つから選ぶ。どちらも同じテンプレート・同じ SPA のビルドで、`web.yaml` のパラメータ `ApiOriginDomain` と `config.json` で切り替える。

全体の構成と共通の準備は [../DEPLOY.md](../DEPLOY.md)、API のデプロイは [../go/DEPLOY.md](../go/DEPLOY.md) / [../node/DEPLOY.md](../node/DEPLOY.md)。GitHub Actions からのデプロイは [../CI.md](../CI.md) 4章。

| 構成 | API への経路 | `ApiOriginDomain` | SPA の `apiBaseUrl` | API の `PublicBaseUrl` | CORS | CSP の API の分 |
|---|---|---|---|---|---|---|
| **直結** | ブラウザ → API Gateway（execute-api の URL）。SPA とはオリジンが別 | 空 | `$API_URL` | 空（execute-api の URL） | 必要（5章） | `connect-src`・`img-src` に `$API_URL` |
| **統合** | ブラウザ → CloudFront（`/v1/*`）→ API Gateway。SPA と同じオリジン | `$API_DOMAIN` | `""`（同じオリジン） | `$WEB_URL`（CloudFront の URL） | 不要 | `'self'` だけ |

```
直結:
利用者のブラウザ ──HTTPS──▶ CloudFront（既定のルートオブジェクト index.html、セキュリティヘッダー）
                              └─ OAC ──▶ S3 バケット（非公開。index.html、assets/*、config.json）
SPA の JS ──fetch / <img>──▶ チケット API（execute-api の URL。CORS で SPA のオリジンを許可する）

統合:
利用者のブラウザ ──HTTPS──▶ CloudFront ─┬─ /*    ─ OAC ──▶ S3 バケット（キャッシュする。セキュリティヘッダー）
                                         └─ /v1/* ────────▶ チケット API（execute-api。キャッシュしない。Host 以外のヘッダー・クエリ・ボディをそのまま渡す）
```

- 画像のアップロードの上限は、今はどちらの構成でも **4MB**（Lambda の上限で決まる）。統合の CloudFront に WAF を付けると変わりうる。経路ごとの上限と、上限を下げる方法は ../DESIGN.md 5章（共通事項の表）。上限を下げるときは、API の `MaxImageBytes` と `config.json` の `maxImageBytes` を同じ値にする
- 統合でも、execute-api の URL は CloudFront を通さずに直接呼べる（WAF やレート制限を迂回できる）。防ぐには追加の作業が要る（11章）
- 上限を超えた画像を送ったときの応答（API Gateway が返すもの）は、AWS 上で確かめる（12章）。WAF の Web ACL はテンプレートに含めていない。作り方は 13章
- 経緯: [../notes/adr-0001-cloudfront-split.md](../notes/adr-0001-cloudfront-split.md)

| 項目 | 内容 |
|---|---|
| スタック名 | `ticketqr-web-$IMPL`（どちらの実装の API を使うかで分ける。SPA 自体は同じビルド）。直結・統合のどちらでも同じスタック |
| S3 バケット | 非公開（パブリックアクセスはすべてブロック）。CloudFront の OAC だけが読める |
| CloudFront | HTTPS へリダイレクト、既定のルートオブジェクト `index.html`（hash モードのルーティングなので、ほかのパスを `index.html` に向ける設定は不要）、マネージドのキャッシュポリシー CachingOptimized |
| セキュリティヘッダー | Response Headers Policy で CSP・HSTS・`X-Content-Type-Options`・`Referrer-Policy: no-referrer`・`X-Frame-Options: DENY` を付ける（DESIGN.md 9章） |
| `config.json` | 環境ごとに作ってアップロードする（ビルドには埋め込まない）。API の URL（統合では `""`）、使う発行方式（`modes`）、画像の上限（`maxImageBytes`。任意）を書く |
| `/v1/*`（統合だけ） | オリジンは API Gateway（HTTPS だけ）。マネージドのキャッシュポリシー CachingDisabled、オリジンリクエストポリシー AllViewerExceptHostHeader、すべてのメソッド、オリジンの応答のタイムアウト 30 秒。SPA のセキュリティヘッダーは付けない（API が自分で付ける） |

## 1. 前提

- チケット API をデプロイ済みで、`$API_URL` が分かっていること（[../go/DEPLOY.md](../go/DEPLOY.md) または [../node/DEPLOY.md](../node/DEPLOY.md)）
- 作業ディレクトリは `docs/st`。`AWS_REGION`・`ACCOUNT_ID`・`IMPL`（使う API の実装。`go` / `node`）を設定しておく（../DEPLOY.md 1章）
- Node.js 24（SPA のビルド）、手動で削除する場合は `jq`
- デプロイする人の権限: ../DEPLOY.md 1章のものに加えて、`s3:CreateBucket` / `PutBucketPolicy` / `PutObject` / `DeleteObject` / `ListBucket`、`cloudfront:*`（ディストリビューション、OAC、Response Headers Policy、無効化）

```sh
echo $API_URL   # https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com（末尾の / は付けない）
export WORK=$(mktemp -d)   # 設定ファイルなどの一時置き場

# 統合で使う: API のスタックの出力 ApiDomain（execute-api のドメイン。https:// なし）
export API_DOMAIN=$(aws cloudformation describe-stacks --stack-name ticketqr-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='ApiDomain'].OutputValue" --output text)
# 手動で作った API・SAM で作った API（スタック ticketqr-sam-$IMPL）の場合は、$API_URL から作ってもよい
# export API_DOMAIN=${API_URL#https://}
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

出力を取り出すコマンドは、直結・統合で共通（3.1 の末尾）。

### 3.1 直結

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

### 3.2 統合（SPA と API を1つの CloudFront にまとめる）

API と CloudFront が互いの URL を使う（CloudFront は API のドメイン、API は `PublicBaseUrl` に CloudFront の URL）ので、初回は次の順番にする。独自ドメインを使う場合は URL が先に決まるので、API を最初から `PublicBaseUrl` 付きで作れば、1 回で済む。

1. API をデプロイする（`PublicBaseUrl` は空のまま。../go/DEPLOY.md / ../node/DEPLOY.md 4-A）。1章で `$API_DOMAIN` を取り出す
2. Web のスタックを作る（下のコマンド）。`$WEB_URL` などを 3.1 の末尾のコマンドで取り出す
3. API をもう一度デプロイする。4-A.1 の `aws cloudformation deploy` に `PublicBaseUrl=$WEB_URL` を足す（QR 画像の URL・チケット表示ページへのリダイレクト先・API の表示ページの CSP が、CloudFront のオリジンになる）。以後の API のデプロイでも毎回付ける
4. `config.json` を `apiBaseUrl: ""` で作ってアップロードする（6章）。CORS の設定（5章）は要らない

```sh
aws cloudformation deploy \
  --stack-name ticketqr-web-$IMPL \
  --template-file infra/cloudformation/web.yaml \
  --parameter-overrides \
    ApiOriginDomain=$API_DOMAIN
# 出力は 3.1 と同じコマンドで取り出す（WebUrl が API の PublicBaseUrl になる）。出力 Layout は unified

# 3. API に CloudFront の URL を教える（例: CloudFormation。ほかのパラメータは各実装の DEPLOY.md 4-A.1 と同じものを付ける）
aws cloudformation deploy \
  --stack-name ticketqr-$IMPL \
  --template-file infra/cloudformation/api.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Impl=$IMPL \
    ArtifactBucket=$ARTIFACT_BUCKET \
    ArtifactPrefix=$ARTIFACT_PREFIX \
    SigningSaltParameterName=$SALT_PARAM \
    TicketCodeSuffixParameterName=$CODE_SUFFIX_PARAM \
    PublicBaseUrl=$WEB_URL
```

- SAM で作った API（../infra/sam/README.md）でも同じ。`sam deploy` の `--parameter-overrides` に `PublicBaseUrl=$WEB_URL` を足す
- 手動で作った API（各実装の DEPLOY.md 4-B）は、2つの関数の環境変数 `PUBLIC_BASE_URL` を `$WEB_URL` にする（`aws lambda update-function-configuration`。4-B.3 のコマンドの `PUBLIC_BASE_URL=$API_URL` を置き換える）

### 3.3 パラメータ

| パラメータ | 既定値 | 内容 |
|---|---|---|
| `ApiOriginDomain` | 空 | **統合だけ**。`/v1/*` を振り分ける API のドメイン（`$API_DOMAIN`。`https://` なし）。空なら直結 |
| `ApiBaseUrl` | 空 | **直結だけ（必須）**。チケット API のオリジン（`$API_URL`）。CSP の `img-src` と `connect-src` に入る（`connect-src` には、SPA が自分のオリジンから `config.json` を `fetch` するための `'self'` も入る）。統合では使わない（CSP は `'self'` だけ） |
| `FormActionSource` | `'none'` | CSP の `form-action`。フォーム送信方式（`modes` の `form`）を有効にする環境だけ、直結では `$API_URL`、統合では `"'self'"` にする |
| `WebAclArn` | 空 | 付ける AWS WAF の Web ACL の ARN（任意。スコープ CLOUDFRONT、us-east-1 で作る。作り方は 13章）。統合では API も守る。**AWS のマネージドルール Core rule set の `SizeRestrictions_BODY`（8KB 超をブロック）を、`/v1/tickets` と `/v1/tickets/qr-inline` では除外する**（しないと、画像のアップロードがすべて 403 になる。../DESIGN.md 5章） |
| `PriceClass` | `PriceClass_200` | CloudFront の配信地域（日本を含む） |

- 直結で `ApiBaseUrl` を指定しないと、スタックの作成・更新がルール（`DirectLayoutNeedsApiBaseUrl`）で失敗する
- CloudFront のディストリビューションの作成には、数分〜十数分かかる
- 直結で API の URL が変わったら、`ApiBaseUrl` を変えて同じコマンドを実行する（CSP が更新される）。`config.json` も作り直す（6章）。統合で API を作り直した（ドメインが変わった）ときは、`ApiOriginDomain` を変えて実行する（`config.json` はそのまま）
- 各実装の DEPLOY.md と同じく、`aws cloudformation deploy` には毎回すべてのパラメータを付ける。統合の環境で `ApiOriginDomain` を付け忘れると直結に戻ろうとし、`ApiBaseUrl` がないので失敗する

## 4. S3 と CloudFront の作成: 手動（AWS CLI）

CloudFormation を使わない場合。3.1（直結）と同じ構成を作る。統合にするときは、4.1 の変更を加える。

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

### 4.1 統合にする場合の変更

上のコマンドの途中で、次のように変える。そのあと、3.2 の 3・4（API の `PUBLIC_BASE_URL` と `config.json`）を行う。

- `headers.json` の CSP: `img-src 'self' data:; connect-src 'self'`（`$API_URL` を消す）。フォーム送信方式を使うなら `form-action 'self'`
- `distribution.json`: `Origins` に API を足し、`/v1/*` の振る舞い（`CacheBehaviors`）を足す。`"Comment"` は `"ticketqr-web-$IMPL SPA + API"` にする

```sh
# distribution.json を作ったあと、create-distribution の前に実行する
jq --arg api "$API_DOMAIN" '
  .Origins = { Quantity: 2, Items: (.Origins.Items + [ {
    Id: "api", DomainName: $api,
    CustomOriginConfig: { HTTPPort: 80, HTTPSPort: 443, OriginProtocolPolicy: "https-only",
      OriginSslProtocols: { Quantity: 1, Items: ["TLSv1.2"] }, OriginReadTimeout: 30, OriginKeepaliveTimeout: 5 }
  } ]) }
  | .CacheBehaviors = { Quantity: 1, Items: [ {
    PathPattern: "/v1/*", TargetOriginId: "api", ViewerProtocolPolicy: "https-only",
    AllowedMethods: { Quantity: 7, Items: ["GET","HEAD","OPTIONS","PUT","PATCH","POST","DELETE"],
      CachedMethods: { Quantity: 2, Items: ["GET","HEAD"] } },
    Compress: false,
    CachePolicyId: "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    OriginRequestPolicyId: "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  } ] }' $WORK/distribution.json > $WORK/distribution-unified.json
mv $WORK/distribution-unified.json $WORK/distribution.json
```

- `4135ea2d-…` はマネージドのキャッシュポリシー CachingDisabled、`b689b0a8-…` はマネージドのオリジンリクエストポリシー AllViewerExceptHostHeader（Host は execute-api のものにする。ほかのヘッダー・クエリ文字列・Cookie はそのまま）の ID

## 5. チケット API の CORS 設定（直結だけ）

**統合では不要**（SPA と API が同じオリジン）。直結から統合に切り替えた環境では、残っている CORS の設定を消してよい（9章の `delete-cors-configuration`）。

直結では、SPA（`$WEB_URL`）と API（`$API_URL`）はオリジンが違う。SPA が発行の応答（JSON）を読めるように、**API Gateway の CORS 設定で SPA のオリジンを許可する**（../E2E.md 4.3）。これがないと、メインの画面遷移方式が動かない。

```sh
# 手動で作った API: $API_ID は、各実装の DEPLOY.md 4-B.1.2 で取得したもの
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
# 直結: API の URL
cat > $WORK/config.json <<EOF
{ "apiBaseUrl": "$API_URL", "modes": ["page"] }
EOF
# 統合: 同じオリジン（"" = SPA と同じ CloudFront の /v1/*）
cat > $WORK/config.json <<EOF
{ "apiBaseUrl": "", "modes": ["page"] }
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
- 画像の上限を 4MB より下げた環境（API の `MaxImageBytes`）では、`config.json` に同じ値の `"maxImageBytes": 2097152` などを足す（省略すると 4MB。4MB より大きい値は、SPA が設定の読み込みのエラーにする）。SPA は送る前にこの値で確かめ、「画像のサイズが大きすぎます（2MB まで）」のように出す
- `modes` に `form` を入れるときは、CSP の `form-action` も変える（3章の `FormActionSource`、4章の `headers.json`）

## 7. 動作確認

```sh
# SPA とセキュリティヘッダー
curl -sI $WEB_URL/ | grep -iE '^(HTTP|content-type|content-security-policy|strict-transport-security|x-content-type-options|referrer-policy|x-frame-options)'
curl -s $WEB_URL/config.json; echo

# S3 を直接読めないこと（非公開）→ 403
curl -s -o /dev/null -w '%{http_code}\n' https://$WEB_BUCKET.s3.$AWS_REGION.amazonaws.com/index.html

# 直結: CORS。SPA のオリジンから発行すると、応答に Access-Control-Allow-Origin が付く
curl -s -o /dev/null -D - -H "Origin: $WEB_URL" -H 'Accept: application/json' \
  -F image=@testdata/images/photo.jpg $API_URL/v1/tickets | grep -iE '^(HTTP|access-control-allow-origin)'

# 統合: CloudFront 経由で発行できる（201）。qrUrl が $WEB_URL で始まる（API の PublicBaseUrl）
curl -s -H 'Accept: application/json' -F image=@testdata/images/photo.jpg $WEB_URL/v1/tickets; echo
# 統合: API の応答はキャッシュされない（x-cache が Miss from cloudfront）。SPA の CSP は付かない（API 自身のヘッダーが付く）
curl -s -o /dev/null -D - -H 'Accept: application/json' -F image=@testdata/images/photo.jpg $WEB_URL/v1/tickets \
  | grep -iE '^(HTTP|x-cache|content-security-policy|cache-control)'
# 統合: SPA の CSP に API のオリジンが入っていない（'self' だけ）
curl -sI $WEB_URL/ | grep -i '^content-security-policy'
```

ブラウザで `$WEB_URL` を開き、証明書の画像を選んで「発行する」を押す。SPA のチケット画面（`#/tickets/{code}?sig=…`）に移り、QR が表示されれば成功。その画面をリロードしても、同じチケットが表示される（再発行されない）。

うまくいかないとき:

| 症状 | 確認すること |
|---|---|
| 「設定を読み込めませんでした」 | `config.json` がアップロードされているか、JSON の形が正しいか（`apiBaseUrl` は `https://` で始まり、末尾に `/` を付けない） |
| 「発行できませんでした」（ブラウザの開発者ツールに CORS のエラー） | 直結: 5章の CORS 設定。`AllowOrigins` が `$WEB_URL` と完全に一致しているか。統合: `config.json` の `apiBaseUrl` が `""` になっているか（API の URL のままだと、別オリジンへの通信になる） |
| 統合で `/v1/...` が 403（S3 の XML のエラー） | CloudFront に `/v1/*` の振る舞いがない（`ApiOriginDomain` を付けずに更新した、など）。スタックの出力 `Layout` が `unified` か |
| 統合で `/v1/...` が 403 `{"message":"Forbidden"}` / 404 `{"message":"Not Found"}` | Host が execute-api のものになっていない（オリジンリクエストポリシーが AllViewerExceptHostHeader か）、または `ApiOriginDomain` が違う |
| 統合で、チケット画面の QR が出ない・リダイレクト先が execute-api の URL | API の `PublicBaseUrl` が `$WEB_URL` になっていない（3.2 の 3） |
| 画像を送ると 403（WAF を付けた環境） | WAF の `SizeRestrictions_BODY` が画像（8KB 超）をブロックしている、または画像のバイト列がボディを検査するルールに誤って一致している（13.5） |
| 開発者ツールに CSP のエラー | CSP の `connect-src` / `img-src` の API のオリジンが `$API_URL` と一致しているか（3章の `ApiBaseUrl`、4章の `headers.json`）。`config.json` が読めないときは、`connect-src` に `'self'` があるか |
| 古い画面のまま | 6章の無効化（`create-invalidation`）をしたか |

### 7.1 統合での API のエラーの応答

CloudFront は、API のエラーの応答（ステータスと JSON の本文）を**変えずにそのまま返す**。2026-10-10 に、統合の環境で、CloudFront 経由の発行 API が解析結果のエラーを 422 で返すことを確かめた（利用者による確認。本文の中身までは厳密に比べていない）。

そのままになる理由:

| 理由 | 内容 |
|---|---|
| カスタムエラーページがない | `web.yaml` に `CustomErrorResponses` を書いていない。CloudFront はオリジンのステータスと本文を、そのまま利用者に返す |
| キャッシュされない | `/v1/*` はマネージドのキャッシュポリシー CachingDisabled。このポリシーでは、CloudFront はエラーの応答（404・5xx など）もキャッシュしない（CloudFront の開発者ガイド「How CloudFront processes HTTP 4xx and 5xx status codes from your origin」）。さらに、発行は POST で、CloudFront は GET・HEAD 以外をキャッシュしない。API もすべての応答に `Cache-Control: no-store` を付けている |

エラーの応答を返すのは、次の4か所。SPA が文言を出し分けられるのは、API の JSON（`{"error":{"code":…}}`）だけ。ほかは「発行できませんでした。もう一度お試しください」になる。

| 返すところ | 例 | 見分け方 |
|---|---|---|
| API（Lambda） | 400 / 403 / 404 / 413 / 415 / 422（`IMAGE_REJECTED`・`IMAGE_RETRY`）/ 502 / 504（../DESIGN.md のエラーコードの表） | 本文が `{"error":{"code":…}}`。`apigw-requestid` が付く |
| API Gateway | Lambda まで届かないとき（大きすぎる画像など。12章）、ルートがないとき | 本文が `{"message":…}`。`apigw-requestid` が付く |
| CloudFront | API Gateway につながらない・30 秒以内に応答がない（502 / 504） | CloudFront の HTML の本文。`x-cache: Error from cloudfront`、`apigw-requestid` が付かない |
| WAF（付けた環境） | ブロックしたとき（403） | CloudFront の HTML の本文。WAF のログ（13.4）に出る |

確かめるときは、直結と統合で同じステータス・本文になることを比べる（解析サーバーが REJECT / RETRY を返す画像があれば 422 も。なければ 415 と 403 で足りる）:

```sh
for base in $API_URL $WEB_URL; do
  echo "== $base"
  # 415 UNSUPPORTED_MEDIA_TYPE（画像でないファイル）
  curl -s -w '  status=%{http_code}\n' -H 'Accept: application/json' -F image=@DESIGN.md $base/v1/tickets
  # 403（署名の改ざん）
  curl -s -w '  status=%{http_code}\n' "$base/v1/tickets/2026101000000000000000000040008000000000000000TQR/qr?sig=AAAAAAAAAAAAAAAAAAAAAA"
done
```

- **`CustomErrorResponses`（カスタムエラーページ）を足さない**。SPA でよく使う「403・404 を `index.html` にする」設定は、ディストリビューション全体（`/v1/*` を含む）に効く。足すと、API の 403（署名の照合の失敗）や 404 が、200 の `index.html` に変わってしまう。この SPA は hash モードのルーティングなので、その設定は要らない
- `/v1/*` のキャッシュポリシーを CachingDisabled 以外にすると、GET の 404・5xx（QR 画像 API・チケット表示ページ）が、既定で 10 秒キャッシュされるようになる

## 8. 更新

SPA を変えたときは、2章のビルドと 6章のアップロード（無効化を含む）を行う。`config.json` だけを変えるときは、6章の `config.json` のアップロードと無効化だけでよい。

セキュリティヘッダー（CSP など）を変えたとき（例: `connect-src` に `'self'` を足したとき）:

```sh
# CloudFormation（3章）の場合: 同じコマンドをもう一度実行する（Response Headers Policy だけが更新される）
# 直結は ApiBaseUrl=$API_URL、統合は ApiOriginDomain=$API_DOMAIN（3.1 / 3.2）
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
aws apigatewayv2 delete-cors-configuration --api-id $API_ID   # 直結だけ
```

- 統合の環境で Web のスタックだけを消して API を残すときは、先に API の `PublicBaseUrl` を空に戻す（3.2 の 3 のコマンドから `PublicBaseUrl` を外して実行する）。そのままだと、QR 画像の URL が消えた CloudFront を指す

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

## 10. 直結と統合の切り替え

同じスタックのまま、パラメータを変えて切り替えられる（バケットとディストリビューションは作り直さない。CloudFront への反映に数分〜十数分かかる）。

| 向き | 手順 |
|---|---|
| 直結 → 統合 | 1. 3.2 のコマンド（`ApiOriginDomain=$API_DOMAIN`）で Web のスタックを更新する。2. API を `PublicBaseUrl=$WEB_URL` で更新する。3. `config.json` を `apiBaseUrl: ""` にしてアップロードし、無効化する（6章）。4. CORS の設定を消す（任意） |
| 統合 → 直結 | 1. 5章の CORS を設定する。2. `config.json` を `apiBaseUrl: "$API_URL"` にしてアップロードし、無効化する。3. API の `PublicBaseUrl` を空に戻す。4. 3.1 のコマンド（`ApiBaseUrl=$API_URL`）で Web のスタックを更新する |

- 切り替えの途中でも SPA が API を呼べる順番にしてある（統合へは、`/v1/*` を先に用意してから SPA を向ける。直結へは、CORS を先に設定してから SPA を向け、最後に `/v1/*` を外す）
- 切り替えの前に発行したチケットの URL（QR 画像・チケット表示ページ）は、古い `PublicBaseUrl` のオリジンのまま。execute-api の URL は統合でも使えるので、直結 → 統合では古い URL も使える。統合 → 直結では、4. のあとは CloudFront の `/v1/*` の URL が使えなくなる。SPA のチケット画面（`#/tickets/{code}?sig=…`）は `config.json` から QR の URL を作るので、影響を受けない

## 11. 統合で、CloudFront を通らないアクセスを防ぐ（未実装）

統合でも、execute-api の URL（`$API_URL`）は CloudFront を通さずに呼べる。WAF やレート制限を CloudFront に付けても、直接呼ばれると効かない。防ぐ方法は次のとおり（まだ実装していない）。

| 方法 | 内容 | 作業 |
|---|---|---|
| 秘密のヘッダー | CloudFront がオリジン（API）へのリクエストに秘密の値のヘッダー（例: `X-Origin-Verify`）を付け、API がそれを確かめる（なければ 403） | `web.yaml` の API のオリジンに `OriginCustomHeaders`、API（Go・Node）にヘッダーの照合、秘密の値の保存（Parameter Store）と入れ替えの手順 |
| 独自ドメイン + `DisableExecuteApiEndpoint` | API Gateway に独自ドメインを付け、execute-api の既定の URL を無効にする。CloudFront のオリジンは独自ドメインにする | 独自ドメインと証明書（ACM）、`api.yaml` の変更。独自ドメインも直接呼べるので、これだけでは迂回は防げない（秘密のヘッダーと組み合わせる） |

## 12. 上限を超えた画像を送ったときの応答の確認

API は 4MB（または `MaxImageBytes`）を超えた画像に、JSON の 413 `PAYLOAD_TOO_LARGE` を返す。ただし、Lambda の上限（6MB。base64 にしたあとの大きさ）や API Gateway の上限（10MB）を超えたリクエストは、Lambda まで届かない。そのときに **API Gateway（統合では CloudFront 経由）が何を返すかは、まだ確かめていない**（../DESIGN.md 5章）。次の手順で確かめ、結果を 12.3 の表と ../DESIGN.md 5章に書く。

SPA は送る前に `maxImageBytes` で止めるので、普段は起きない。ただし、フォーム送信方式（送る前の確認をしない）や、SPA を通さない呼び出しでは起きる。応答によって、SPA の表示も変わる（12.4）。

### 12.1 送るファイル

API は形式より先に大きさを確かめるので、中身は画像でなくてよい（ゼロで埋めたファイル）。

| ケース | 大きさ | 期待すること |
|---|---|---|
| A | 4MB + 1 バイト（4194305） | Lambda まで届き、API が 413 `PAYLOAD_TOO_LARGE`（JSON）を返す。比べるための基準 |
| B | 5MB（5242880） | base64 で 約6.7MB になり、Lambda の 6MB を超える。API Gateway の 10MB 以下。**未確認** |
| C | 11MB（11534336） | API Gateway の 10MB を超える。**未確認** |

```sh
export WORK=$(mktemp -d)
head -c 4194305  /dev/zero > $WORK/a.bin
head -c 5242880  /dev/zero > $WORK/b.bin
head -c 11534336 /dev/zero > $WORK/c.bin
```

- `MaxImageBytes` を 4MB より下げた環境では、A をその値 + 1 バイトにする
- 送るのは数十 MB だけで、チケットは発行されない（A は API が大きさで断り、解析サーバーも呼ばれない）

### 12.2 送って記録する

```sh
# $1 = 送り先のオリジン、$2 = ファイル。ステータス、主なヘッダー、本文の先頭を出す
probe() {
  curl -s -o $WORK/body -D $WORK/headers -w 'status=%{http_code} time=%{time_total}s\n' \
    -H "Origin: $WEB_URL" -H 'Accept: application/json' \
    -F "image=@$2;type=image/jpeg" "$1/v1/tickets"
  grep -iE '^(content-type|content-length|apigw-requestid|access-control-allow-origin|x-cache|x-amz-cf-id|server):' $WORK/headers
  head -c 300 $WORK/body; echo; echo
}

# 直結: API Gateway に直接
for f in a b c; do echo "== direct $f"; probe $API_URL $WORK/$f.bin; done

# 統合: CloudFront の /v1/*（統合の環境だけ）
for f in a b c; do echo "== unified $f"; probe $WEB_URL $WORK/$f.bin; done

# QR 同梱付与 API（/v1/tickets/qr-inline）も同じか（B だけで十分）
curl -s -o /dev/null -w 'status=%{http_code}\n' -F "image=@$WORK/b.bin;type=image/jpeg" $API_URL/v1/tickets/qr-inline
```

ログで、どこで止まったかを確かめる:

```sh
# API Gateway のアクセスログ（CloudFormation・SAM で作った API）: status と integrationError（Lambda を呼べなかった理由）
aws logs tail /aws/apigateway/ticketqr-$IMPL --since 10m --format short

# Lambda のログ: A だけが "request completed"（status 413）として出る。B・C が出なければ、Lambda は呼ばれていない
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 10m --filter-pattern '"request completed"'
```

- 統合で WAF を付けている環境では、WAF のログ（13.4）でブロックされていないことも確かめる。WAF にブロックされると、B・C より先に 403 になる（CloudFront の HTML の応答）
- `x-cache: Error from cloudfront` は、CloudFront がオリジン（API Gateway）からエラーを受け取ったか、CloudFront 自身がエラーを返したことを示す。`apigw-requestid` があれば、API Gateway まで届いている

### 12.3 結果（確かめたら書く）

| ケース | 経路 | ステータス | Content-Type・本文 | `access-control-allow-origin` | アクセスログの `status` / `integrationError` | 確かめた日 |
|---|---|---|---|---|---|---|
| A | 直結 | （期待: 413） | （期待: JSON の `PAYLOAD_TOO_LARGE`） | （期待: 付く） | | |
| B | 直結 | | | | | |
| C | 直結 | | | | | |
| A | 統合 | （期待: 413） | （期待: JSON の `PAYLOAD_TOO_LARGE`） | （同じオリジンなので関係ない） | | |
| B | 統合 | | | - | | |
| C | 統合 | | | - | | |

### 12.4 結果を見て決めること

| 結果 | SPA での見え方 | 対応 |
|---|---|---|
| JSON でない応答（例: `{"message":"Request Entity Too Large"}`、`{"message":"Internal Server Error"}`） | `fetch` の方式では「発行できませんでした。もう一度お試しください」（想定外の応答 `UNEXPECTED`） | ステータスが 413 なら、SPA で 413 を「画像のサイズが大きすぎます」として扱う（`src/api/tickets.ts` で、本文が API の JSON でなくても 413 なら `PAYLOAD_TOO_LARGE` にする） |
| 直結で `access-control-allow-origin` が付かない | ブラウザが応答を読めず、通信エラー（`NETWORK`）と同じ表示になる | API Gateway のエラーの応答に CORS のヘッダーが付かないなら、SPA 側では区別できない。送る前の確認（`maxImageBytes`）に頼る |
| フォーム送信方式 | API Gateway の応答（JSON の文字列）がそのまま画面に出る | API のエラーページにはならない。上限を超えそうな利用者が多ければ、フォーム送信方式を使わないか、SPA 側で送る前に確かめる |

結果は ../DESIGN.md 5章の表（「Lambda の同期呼び出しのリクエスト」の行）にも書き、「要確認」を消す。

## 13. WAF の Web ACL（統合の構成。任意）

`web.yaml` は、パラメータ `WebAclArn` で**既存の** Web ACL を CloudFront に付けるだけで、Web ACL 自体は作らない（テンプレートに含めていない）。ここでは、Web ACL の中身の案と、AWS CLI で作る手順を書く。**未検証**（AWS 上で作っていない）。

- **統合の構成で使う**。直結では、CloudFront に付けても SPA の静的ファイルしか守れない（API Gateway の HTTP API には WAF を付けられない）
- 統合でも、execute-api の URL を直接呼ばれると迂回される（11章）
- CloudFront に付ける Web ACL は、スコープ `CLOUDFRONT` で、**us-east-1** に作る（Web のスタックのリージョンとは関係ない）
- 採否とレート制限の値は、まだ決まっていない（../DESIGN.md の「決めておきたいこと」7）

### 13.1 ルールの案

上から順に評価する（`Priority` の小さい順）。既定の動作は許可（`Allow`）。

| 優先度 | 名前 | 中身 | 動作 | 理由 |
|---|---|---|---|---|
| 0 | `rate-limit-upload` | 送信元 IP ごとに、5分間に `POST /v1/tickets`・`POST /v1/tickets/qr-inline` が 100 回を超えたら | ブロック | 発行の連打と、画像解析サーバーへの負荷を抑える。値は仮（13.6） |
| 1 | `aws-ip-reputation` | AWS のマネージドルール `AWSManagedRulesAmazonIpReputationList` | グループの動作（ブロック） | 攻撃元として知られた IP を止める |
| 2 | `aws-common` | AWS のマネージドルール `AWSManagedRulesCommonRuleSet`（Core rule set）。**`SizeRestrictions_BODY` だけ Count に変える** | グループの動作（ブロック）。`SizeRestrictions_BODY` はラベルを付けるだけ | 一般的な攻撃。`SizeRestrictions_BODY` は 8KB を超えるボディをブロックするので、そのままだと画像がすべて止まる |
| 3 | `block-large-body-except-upload` | 優先度 2 で `SizeRestrictions_BODY` のラベルが付き、**かつ**パスが画像を受け取る2つ（`^/v1/tickets(/qr-inline)?$`）ではない | ブロック | 画像を受け取る API 以外では、`SizeRestrictions_BODY` を元どおり効かせる |
| 4 | `aws-known-bad-inputs` | AWS のマネージドルール `AWSManagedRulesKnownBadInputsRuleSet` | グループの動作（ブロック） | Log4j などの既知の攻撃 |

- WCU（Web ACL の容量）は 約 950（Core rule set 700、Known bad inputs 200、IP reputation 25、自作のルール 数十）。既定の上限 1,500 に収まる
- ボディの検査の大きさは既定の 16KB のまま（`AssociationConfig`）。画像の先頭 16KB だけが検査される。広げても（最大 64KB）画像の中身は守れず、料金が増えるだけなので広げない
- WAF では、ボディの大きさそのもの（4MB など）は制限できない（検査できるのは先頭 64KB まで）。大きさの制限は API（`MaxImageBytes`）と SPA（`maxImageBytes`）が行う

### 13.2 作る（AWS CLI）

```sh
export WAF_REGION=us-east-1   # CloudFront 用の Web ACL は us-east-1
UPLOAD_PATH='^/v1/tickets(/qr-inline)?$'
vis() { echo "{\"SampledRequestsEnabled\":true,\"CloudWatchMetricsEnabled\":true,\"MetricName\":\"$1\"}"; }

cat > $WORK/waf-rules.json <<EOF
[
  {
    "Name": "rate-limit-upload", "Priority": 0, "Action": { "Block": {} },
    "Statement": { "RateBasedStatement": {
      "Limit": 100, "EvaluationWindowSec": 300, "AggregateKeyType": "IP",
      "ScopeDownStatement": { "AndStatement": { "Statements": [
        { "RegexMatchStatement": { "RegexString": "$UPLOAD_PATH", "FieldToMatch": { "UriPath": {} },
          "TextTransformations": [ { "Priority": 0, "Type": "NONE" } ] } },
        { "ByteMatchStatement": { "SearchString": "POST", "FieldToMatch": { "Method": {} },
          "PositionalConstraint": "EXACTLY", "TextTransformations": [ { "Priority": 0, "Type": "NONE" } ] } }
      ] } }
    } },
    "VisibilityConfig": $(vis rate-limit-upload)
  },
  {
    "Name": "aws-ip-reputation", "Priority": 1, "OverrideAction": { "None": {} },
    "Statement": { "ManagedRuleGroupStatement": { "VendorName": "AWS", "Name": "AWSManagedRulesAmazonIpReputationList" } },
    "VisibilityConfig": $(vis aws-ip-reputation)
  },
  {
    "Name": "aws-common", "Priority": 2, "OverrideAction": { "None": {} },
    "Statement": { "ManagedRuleGroupStatement": { "VendorName": "AWS", "Name": "AWSManagedRulesCommonRuleSet",
      "RuleActionOverrides": [ { "Name": "SizeRestrictions_BODY", "ActionToUse": { "Count": {} } } ] } },
    "VisibilityConfig": $(vis aws-common)
  },
  {
    "Name": "block-large-body-except-upload", "Priority": 3, "Action": { "Block": {} },
    "Statement": { "AndStatement": { "Statements": [
      { "LabelMatchStatement": { "Scope": "LABEL", "Key": "awswaf:managed:aws:core-rule-set:SizeRestrictions_Body" } },
      { "NotStatement": { "Statement": { "RegexMatchStatement": { "RegexString": "$UPLOAD_PATH",
        "FieldToMatch": { "UriPath": {} }, "TextTransformations": [ { "Priority": 0, "Type": "NONE" } ] } } } }
    ] } },
    "VisibilityConfig": $(vis block-large-body-except-upload)
  },
  {
    "Name": "aws-known-bad-inputs", "Priority": 4, "OverrideAction": { "None": {} },
    "Statement": { "ManagedRuleGroupStatement": { "VendorName": "AWS", "Name": "AWSManagedRulesKnownBadInputsRuleSet" } },
    "VisibilityConfig": $(vis aws-known-bad-inputs)
  }
]
EOF
jq empty $WORK/waf-rules.json   # JSON の形を確かめる

export WEB_ACL_ARN=$(aws wafv2 create-web-acl --region $WAF_REGION \
  --name ticketqr-web-$IMPL --scope CLOUDFRONT \
  --default-action Allow={} \
  --visibility-config "$(vis ticketqr-web-$IMPL)" \
  --rules file://$WORK/waf-rules.json \
  --association-config '{"RequestBody":{"CLOUDFRONT":{"DefaultSizeInspectionLimit":"KB_16"}}}' \
  --query Summary.ARN --output text)
echo $WEB_ACL_ARN
```

- デプロイする人の権限: `wafv2:CreateWebACL` / `GetWebACL` / `UpdateWebACL` / `DeleteWebACL` / `ListWebACLs` / `PutLoggingConfiguration` / `GetSampledRequests`、CloudFront に付けるための `wafv2:AssociateWebACL`（CloudFormation が `cloudfront:UpdateDistribution` と一緒に使う）
- 最初は、ブロックせずに様子を見るのが安全。`aws-common` と `aws-known-bad-inputs` の `"OverrideAction": { "None": {} }` を `{ "Count": {} }` に、自作のルールの `"Action": { "Block": {} }` を `{ "Count": {} }` にして作り、13.4 のログで誤検知がないことを確かめてから戻す（13.5）

### 13.3 CloudFront に付ける・外す

```sh
# 付ける: 3.2 のコマンドに WebAclArn を足す（以後のデプロイでも毎回付ける）
aws cloudformation deploy \
  --stack-name ticketqr-web-$IMPL \
  --template-file infra/cloudformation/web.yaml \
  --parameter-overrides \
    ApiOriginDomain=$API_DOMAIN \
    WebAclArn=$WEB_ACL_ARN

# 外す: WebAclArn を付けずに、同じコマンドを実行する
```

- 手動で作ったディストリビューション（4章）では、`distribution.json` に `"WebACLId": "$WEB_ACL_ARN"` を足す（作ったあとなら、`get-distribution-config` で取り出して足し、`update-distribution` する）

### 13.4 ログ

WAF のログは、名前が `aws-waf-logs-` で始まる CloudWatch Logs のロググループに送る（CloudFront 用は us-east-1 に作る）。

```sh
aws logs create-log-group --region $WAF_REGION --log-group-name aws-waf-logs-ticketqr-web-$IMPL
aws logs put-retention-policy --region $WAF_REGION --log-group-name aws-waf-logs-ticketqr-web-$IMPL --retention-in-days 30
aws wafv2 put-logging-configuration --region $WAF_REGION --logging-configuration \
  "ResourceArn=$WEB_ACL_ARN,LogDestinationConfigs=arn:aws:logs:$WAF_REGION:$ACCOUNT_ID:log-group:aws-waf-logs-ticketqr-web-$IMPL"

# ブロック（または Count）されたリクエスト: どのルールに当たったか（terminatingRuleId、ruleGroupList、labels）
aws logs tail --region $WAF_REGION aws-waf-logs-ticketqr-web-$IMPL --since 1h \
  --filter-pattern '{ $.action = "BLOCK" }' --format short
aws logs tail --region $WAF_REGION aws-waf-logs-ticketqr-web-$IMPL --since 1h \
  --filter-pattern '{ $.nonTerminatingMatchingRules[0].action = "COUNT" }' --format short
```

### 13.5 確かめること

| 確かめること | 方法 | 期待 |
|---|---|---|
| 8KB を超える画像が通る | 手元のスマートフォンの写真（数 MB）を、SPA から、または `curl -H 'Accept: application/json' -F image=@写真.jpg $WEB_URL/v1/tickets` で送る | 201。WAF のログに `BLOCK` が出ない。`SizeRestrictions_BODY` は Count として記録される |
| 画像のバイト列が、ボディを検査するルールに誤って一致しない | いろいろな写真（iPhone の HEIC、Android の JPEG、PNG のスクリーンショット）を送り、13.4 のログを見る | `CrossSiteScripting_BODY`・`GenericLFI_BODY`・`GenericRFI_BODY` などに当たらない。当たる場合は、そのルールも `RuleActionOverrides` で Count にし、ルール 3 と同じ形（ラベル + パス）で、画像を受け取る API 以外ではブロックする |
| 画像を受け取る API 以外では、8KB 超のボディが止まる | `curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary @$WORK/a.bin $WEB_URL/v1/tickets/x/view` | 403（ルール 3） |
| 上限を超えた画像の応答が変わらない | 12章の A・B・C を `$WEB_URL` に送る | WAF を付ける前と同じ（WAF にブロックされない） |
| レート制限 | 5分間に 100 回を超えて送る（`testdata/images/photo.jpg` で十分。解析サーバーを `mock` にした環境で行う） | 超えたあとは 403。数分たつと戻る |
| サンプル | `aws wafv2 get-sampled-requests --region $WAF_REGION --web-acl-arn $WEB_ACL_ARN --rule-metric-name aws-common --scope CLOUDFRONT --time-window StartTime=$(date -u -v-1H +%s),EndTime=$(date -u +%s) --max-items 50`（Linux では `date -u -d '-1 hour' +%s`） | 誤検知の例があれば、ここに出る |

### 13.6 決めること・注意

| 項目 | 内容 |
|---|---|
| レート制限の値 | 仮に「送信元 IP ごとに 5分 100 回」。想定の発行量（ピーク 1秒 2件）に比べて十分大きい。ただし、携帯回線や会社のネットワークは多くの利用者が同じ IP を使う（キャリアグレード NAT など）ので、小さくしすぎると正しい利用者が止まる。ログ（13.4）で実際の回数を見て決める |
| 料金（目安。[公式の料金](https://aws.amazon.com/waf/pricing/)で確かめる） | Web ACL 1つ 月 5 USD、ルール（マネージドのルールグループも1つで1ルール）1つ 月 1 USD、リクエスト 100万件あたり 0.60 USD。この案（5ルール）なら、リクエスト以外で月 10 USD ほど。ボディの検査を 16KB より広げると追加の料金がかかる |
| テンプレート化 | 今は CLI で作る。続けて使うなら、us-east-1 に置く別のテンプレート（例: `infra/cloudformation/waf.yaml`。`AWS::WAFv2::WebACL`、`Scope: CLOUDFRONT`）にし、出力の ARN を `web.yaml` の `WebAclArn` に渡す。Web のスタックとはリージョンが違うので、同じテンプレートには入れられない |
| 迂回 | execute-api の URL を直接呼ばれると WAF を通らない（11章） |
| ボットや不正利用の対策 | Bot Control などの追加のマネージドルール（有料）は、この案には入れていない |

### 13.7 更新・削除

```sh
# ルールを変える: waf-rules.json を直して、ロックトークンを付けて更新する
read -r WAF_ID WAF_LOCK < <(aws wafv2 list-web-acls --region $WAF_REGION --scope CLOUDFRONT \
  --query "WebACLs[?Name=='ticketqr-web-$IMPL'] | [0].[Id,LockToken]" --output text)
aws wafv2 update-web-acl --region $WAF_REGION --scope CLOUDFRONT \
  --name ticketqr-web-$IMPL --id $WAF_ID --lock-token $WAF_LOCK \
  --default-action Allow={} \
  --visibility-config "$(vis ticketqr-web-$IMPL)" \
  --rules file://$WORK/waf-rules.json \
  --association-config '{"RequestBody":{"CLOUDFRONT":{"DefaultSizeInspectionLimit":"KB_16"}}}'

# 削除: 先に CloudFront から外す（13.3）。そのあとで消す
aws wafv2 delete-logging-configuration --region $WAF_REGION --resource-arn $WEB_ACL_ARN
read -r WAF_ID WAF_LOCK < <(aws wafv2 list-web-acls --region $WAF_REGION --scope CLOUDFRONT \
  --query "WebACLs[?Name=='ticketqr-web-$IMPL'] | [0].[Id,LockToken]" --output text)
aws wafv2 delete-web-acl --region $WAF_REGION --scope CLOUDFRONT \
  --name ticketqr-web-$IMPL --id $WAF_ID --lock-token $WAF_LOCK
aws logs delete-log-group --region $WAF_REGION --log-group-name aws-waf-logs-ticketqr-web-$IMPL
```

- `update-web-acl` は、ルールの一覧をまるごと置き換える（足したいルールだけを送ると、ほかのルールが消える）
