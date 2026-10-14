# 本番環境のデプロイ手順（実際にやることだけ）

本番の構成で、実際に流すコマンドだけを順番に並べたもの。選択肢・理由・手動（AWS CLI）の手順・トラブルシューティングは書かない（各章の「詳しくは」を参照）。

> 2026-10-14 作成。ここに並べたテンプレート（SAM・ネットワーク・CloudFront の統合・発行の上限）は、どれも AWS 上ではまだ動かしていない（../README.md「確かめていないこと」）。

本番の構成（../README.md で確定しているもの）:

| 項目 | 本番 |
|---|---|
| API の実装 | Go（`IMPL=go`） |
| 経路 | 統合（CloudFront の `/*` → S3、`/v1/*` → API Gateway。CORS の設定は要らない） |
| `tickets` 関数 | VPC のプライベートサブネットに置き、NAT 経由で外の解析サーバーへ（`AnalyzerMode=http`、API キーなし） |
| API のデプロイ | SAM（`infra/sam/go/template.yaml`。VPC の設定が必須） |
| 発行の上限 | `quota-guard.yaml`（1時間 1 万件・1日 10 万件） |
| 発行方式 | 画面遷移方式（`GRANT_MODE=page`） |

作るスタック: `ticketqr-tickets-network`（ネットワーク）、`ticketqr-sam-go`（API）、`ticketqr-web-go`（S3 + CloudFront）、`ticketqr-quota-go`（発行の上限）。example.com の QR（`ticketqr-go-example`）は本番の構成に含めない。

## 0. 準備（毎回）

前提: AWS CLI v2 と本番アカウントのプロファイル（すべての `aws`・`sam deploy` に `--profile $PROFILE` を付けている）、SAM CLI（`uvx --from aws-sam-cli sam` でもよい）、Go（`go/go.mod` のバージョン）、Node.js 24、`openssl`。

```sh
cd docs/st
export PROFILE=ticketqr-prod   # 本番アカウントの AWS CLI のプロファイル名に置き換える（~/.aws/config）
export AWS_REGION=ap-northeast-1
export ACCOUNT_ID=$(aws --profile $PROFILE sts get-caller-identity --query Account --output text)
export IMPL=go
export ARTIFACT_BUCKET=ticketqr-artifacts-$ACCOUNT_ID-$AWS_REGION
export SALT_PARAM=/ticketqr/$IMPL/signing-salt
export CODE_SUFFIX_PARAM=/ticketqr/$IMPL/ticket-code-suffix
export ANALYZER_URL=https://analyzer.example/v1/analyze   # 本番の解析サーバーの接続先に置き換える（未確定）
```

## 1. 初回だけ

### 1.1 成果物バケット

```sh
aws --profile $PROFILE s3api create-bucket --bucket $ARTIFACT_BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_REGION
aws --profile $PROFILE s3api put-public-access-block --bucket $ARTIFACT_BUCKET \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws --profile $PROFILE s3api put-bucket-versioning --bucket $ARTIFACT_BUCKET --versioning-configuration Status=Enabled
```

詳しくは ../DEPLOY.md 2章。

### 1.2 署名用 salt とチケットコードの固定文字列（Parameter Store）

```sh
umask 077
SALT_FILE=$(mktemp)
printf '{"current":"%s"}' "$(openssl rand -base64 32)" > "$SALT_FILE"
aws --profile $PROFILE ssm put-parameter --name $SALT_PARAM --type SecureString \
  --description "Ticket QR signing salt ($IMPL)" --value file://"$SALT_FILE"
rm -f "$SALT_FILE"

aws --profile $PROFILE ssm put-parameter --name $CODE_SUFFIX_PARAM --type String \
  --description "Ticket QR: fixed suffix of ticket codes ($IMPL)" \
  --value 'TQR'   # 本番の固定文字列に置き換える（英数字 1〜32 文字）
```

- salt は作り直さない（変えると、発行済みのチケットの URL がすべて 403 になる）

詳しくは ../go/DEPLOY.md 3章・3.1。

### 1.3 `tickets` 用のネットワーク

N1（既存の VPC と NAT を使う）、N2（すべて新しく作る）、N3（既存のプライベートサブネットを使い、SG だけ作る）の**どれか1つ**を実行する（どれにするかは未確定。../notes/tickets-network.md 6章）。どれもスタック名と出力（`PrivateSubnetIds`・`SecurityGroupId`）は同じなので、2章はそのまま使える。

```sh
# N1: 既存の VPC + 新規のプライベートサブネット + 既存の NAT（値は実際のものに置き換える）
#   作るもの: プライベートサブネット 2（AZ a・c）、ルートテーブル 2（0.0.0.0/0 → 既存の NAT）、tickets の SG（受信なし・送信 443）
#   既存のサブネット・ルートテーブル・NAT は変えない。送信元の IP は既存の NAT のもの（ほかのサービスと共有）。時間課金の追加なし
aws --profile $PROFILE cloudformation deploy --stack-name ticketqr-tickets-network \
  --template-file infra/cloudformation/tickets-network-existing-vpc.yaml \
  --parameter-overrides \
    VpcId=vpc-xxxxxxxx \
    PrivateSubnetCidrA=10.0.20.0/26 \
    PrivateSubnetCidrB=10.0.20.64/26 \
    AvailabilityZoneA=ap-northeast-1a \
    AvailabilityZoneB=ap-northeast-1c \
    NatGatewayIdA=nat-aaaaaaaa \
    NatGatewayIdB=nat-cccccccc

# N2: すべて新規（NAT を AZ ごとに置くなら NatPerAz=true）
#   作るもの: VPC（10.50.0.0/24）、インターネットゲートウェイ、パブリックサブネット 1、NAT + Elastic IP 1、
#             プライベートサブネット 2（AZ a・c）、ルートテーブル 3、tickets の SG（受信なし・送信 443）
#   NatPerAz=true ならパブリックサブネットと NAT + Elastic IP が 2 つずつ。送信元の IP は tickets 専用
#   時間課金: NAT 1 つで月 約 $45 + Elastic IP 月 約 $3.6（NatPerAz=true なら倍）
aws --profile $PROFILE cloudformation deploy --stack-name ticketqr-tickets-network \
  --template-file infra/cloudformation/tickets-network-new-vpc.yaml \
  --parameter-overrides NatPerAz=false

# N3: 既存の VPC + 既存のプライベートサブネット（外に出る経路（NAT など）があるもの。値は実際のものに置き換える）
#   作るもの: tickets の SG（受信なし・送信 443）だけ
#   サブネット・ルートテーブル・NAT は作らず、変えない（サブネットの ID は出力にそのまま渡す）。送信元の IP はそのサブネットの経路の先の NAT のもの。時間課金の追加なし
aws --profile $PROFILE cloudformation deploy --stack-name ticketqr-tickets-network \
  --template-file infra/cloudformation/tickets-network-sg-only.yaml \
  --parameter-overrides \
    VpcId=vpc-xxxxxxxx \
    PrivateSubnetIds=subnet-aaaaaaaa,subnet-cccccccc
```

解析サーバー側に登録してもらう送信元の IP（NAT の固定 IP）を確かめる:

```sh
# N1
aws --profile $PROFILE ec2 describe-nat-gateways --nat-gateway-ids nat-aaaaaaaa nat-cccccccc \
  --query "NatGateways[].NatGatewayAddresses[].PublicIp" --output text
# N2
aws --profile $PROFILE cloudformation describe-stacks --stack-name ticketqr-tickets-network \
  --query "Stacks[0].Outputs[?OutputKey=='NatPublicIps'].OutputValue" --output text
# N3（サブネットのルートテーブルの 0.0.0.0/0 の先の NAT を調べて、その IP を出す）
for NAT in $(aws --profile $PROFILE ec2 describe-route-tables \
  --filters Name=association.subnet-id,Values=subnet-aaaaaaaa,subnet-cccccccc \
  --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" --output text); do
  aws --profile $PROFILE ec2 describe-nat-gateways --nat-gateway-ids $NAT \
    --query "NatGateways[].NatGatewayAddresses[].PublicIp" --output text
done
```

- N3 で上のコマンドが何も出さないときは、サブネットがメインのルートテーブルを使っている（明示的な関連付けがない）か、外への経路が NAT ではない（Transit Gateway など）。経路はネットワークの管理者に確かめる

## 2. API（SAM）

```sh
export TICKETS_SUBNETS=$(aws --profile $PROFILE cloudformation describe-stacks --stack-name ticketqr-tickets-network \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetIds'].OutputValue" --output text)
export TICKETS_SG=$(aws --profile $PROFILE cloudformation describe-stacks --stack-name ticketqr-tickets-network \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroupId'].OutputValue" --output text)
# 初回は空。2回目以降は Web のスタックの URL（3章のあとで設定される）
export WEB_URL=$(aws --profile $PROFILE cloudformation describe-stacks --stack-name ticketqr-web-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='WebUrl'].OutputValue" --output text 2>/dev/null || true)

make -C go test
sam build --template-file infra/sam/go/template.yaml --build-dir infra/sam/go/.aws-sam/build
sam deploy --profile $PROFILE --template-file infra/sam/go/.aws-sam/build/template.yaml \
  --stack-name ticketqr-sam-$IMPL \
  --s3-bucket $ARTIFACT_BUCKET --s3-prefix ticketqr-sam/$IMPL \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides \
    VpcSubnetIds=$TICKETS_SUBNETS \
    VpcSecurityGroupIds=$TICKETS_SG \
    SigningSaltParameterName=$SALT_PARAM \
    TicketCodeSuffixParameterName=$CODE_SUFFIX_PARAM \
    AnalyzerMode=http \
    AnalyzerUrl=$ANALYZER_URL \
    PublicBaseUrl=$WEB_URL
```

- `--parameter-overrides` は毎回すべて付ける（付けなかったものは既定値に戻る。`AnalyzerMode` を落とすと `mock` になり、すべての画像が通る）

詳しくは sam/README.md 3章。

## 3. Web（S3 + CloudFront。統合）

```sh
export API_DOMAIN=$(aws --profile $PROFILE cloudformation describe-stacks --stack-name ticketqr-sam-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='ApiDomain'].OutputValue" --output text)

npm --prefix web ci
npm --prefix web test
GRANT_MODE=page npm --prefix web run build

aws --profile $PROFILE cloudformation deploy \
  --stack-name ticketqr-web-$IMPL \
  --template-file infra/cloudformation/web.yaml \
  --parameter-overrides ApiOriginDomain=$API_DOMAIN

out() { aws --profile $PROFILE cloudformation describe-stacks --stack-name ticketqr-web-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
export WEB_BUCKET=$(out BucketName) DIST_ID=$(out DistributionId) WEB_URL=$(out WebUrl)
echo $WEB_URL   # https://dxxxxxxxxxxxxx.cloudfront.net
```

**初回だけ**: ここで `WEB_URL` が決まるので、2章の `sam deploy` をもう一度実行する（`PublicBaseUrl=$WEB_URL` が入る。QR 画像とチケット表示ページの URL が CloudFront のものになる）。

SPA のアップロード:

```sh
WORK=$(mktemp -d)
echo '{ "apiBaseUrl": "" }' > $WORK/config.json

aws --profile $PROFILE s3 sync web/dist/ s3://$WEB_BUCKET/ --delete \
  --exclude index.html --exclude config.json \
  --cache-control 'public, max-age=31536000, immutable'
aws --profile $PROFILE s3 cp web/dist/index.html s3://$WEB_BUCKET/index.html \
  --cache-control no-cache --content-type 'text/html; charset=utf-8'
aws --profile $PROFILE s3 cp $WORK/config.json s3://$WEB_BUCKET/config.json \
  --cache-control no-cache --content-type application/json
aws --profile $PROFILE cloudfront create-invalidation --distribution-id $DIST_ID --paths /index.html /config.json
```

詳しくは ../web/DEPLOY.md 2章・3.2・6章。

## 4. 発行の上限（初回と、API のスロットリングを変えたとき）

```sh
export API_ID=$(aws --profile $PROFILE cloudformation describe-stacks --stack-name ticketqr-sam-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='ApiId'].OutputValue" --output text)
aws --profile $PROFILE cloudformation deploy \
  --stack-name ticketqr-quota-$IMPL \
  --template-file infra/cloudformation/quota-guard.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides ApiId=$API_ID TicketsFunctionName=ticketqr-$IMPL-tickets
```

詳しくは RATE_LIMITING.md 7章。

## 5. 動作確認

```sh
# 画面（200）とセキュリティヘッダー
curl -sI $WEB_URL/ | grep -iE '^HTTP|content-security-policy'
# CloudFront 経由で発行できる（201）。qrUrl が $WEB_URL で始まる
curl -s -H 'Accept: application/json' -F image=@testdata/images/photo.jpg $WEB_URL/v1/tickets; echo
# 解析サーバーにつながらないと 502 / 504。原因はログ
aws --profile $PROFILE logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 10m
```

最後に、スマートフォンのブラウザで `$WEB_URL` を開き、証明書の写真を送ってチケット（QR）が表示されるところまで確かめる。

## 6. 2回目以降（更新）

| 変えたもの | やること |
|---|---|
| API（Go のコード・API の設定） | 0章 → 2章 |
| SPA | 0章 → 3章 |
| 両方 | 0章 → 2章 → 3章 |

- ロールバック: 戻したいコミットをチェックアウトして、同じ手順を実行する
