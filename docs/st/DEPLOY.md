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
4. 必要なら: 画像解析サーバーのスタブ（この文書の 3章）をデプロイし、API を `http` モードに切り替える（各実装の DEPLOY.md 4-A.3。手動は 4-B.3）
   - VPC 内の解析サーバー（SG だけで許可、API キーなし）に近い形で確かめる場合は、VPC 内のスタブ（3.4。ECS Fargate）を使い、API の `tickets` を VPC に置く（各実装の DEPLOY.md 4-A.4。手動は 4-B.4）

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

本物の画像解析サーバーができるまで、API の `http` モードの接続先に使う（[analyzer-stub/DESIGN.md](analyzer-stub/DESIGN.md)。解析はせず常に valid を返す）。スタブと API キーをここで用意し、API の切り替えは各実装の DEPLOY.md 4-A.3（手動は 4-B.3）で行う。

### 3.1 API キーを作る（初回だけ）

スタブと API の両方が読む API キーを、Parameter Store の SecureString に作る（CloudFormation は SecureString を作れないため、CLI で作る）。

```sh
export STUB_IMPL=node   # スタブの実装: node / python / rust（どれも同じ動き。analyzer-stub/DESIGN.md 5・6章・付録）
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
npm --prefix analyzer-stub/node run build     # Python 版は: analyzer-stub/python/build.sh、Rust 版は: analyzer-stub/rust/build.sh
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

この後、API を `http` モードに切り替える: [go/DEPLOY.md](go/DEPLOY.md) / [node/DEPLOY.md](node/DEPLOY.md) の 4-A.3（手動は 4-B.3。`ANALYZER_URL`・`ANALYZER_KEY_PARAM`・`STUB_IMPL` を使う）。

### 3.3 スタブを削除する

API を `mock` に戻してから削除する（`http` のまま削除すると、発行の API がすべて 502 になる）。

```sh
aws cloudformation delete-stack --stack-name ticketqr-analyzer-stub-$STUB_IMPL
aws ssm delete-parameter --name $ANALYZER_KEY_PARAM   # API キーはスタックの外にあるので別に削除する
```

### 3.4 VPC 内のスタブ（ECS Fargate、プライベートサブネット。任意）

本番の想定（解析サーバーは VPC 内にあり、特定の SG からだけ受け付け、API キーを使わない）に近い形で確かめるためのスタブ。3.1〜3.3（Function URL）とは別のもので、API キーは使わない（`STUB_AUTH=none`）。構成の検討は [notes/analyzer-stub-vpc.md](notes/analyzer-stub-vpc.md)、費用とパターンの違いは [notes/analyzer-stub-cost.md](notes/analyzer-stub-cost.md)。

- スタブは、コンテナ（各実装のローカル用サーバー。`analyzer-stub/{node,python,rust}/Dockerfile`）を Fargate のタスクとして、**確認のときだけ**起動する
- CloudFormation（`analyzer-stub/vpc-template.yaml`）は**既存の VPC とプライベートサブネットを指定する**。VPC から新しく作る場合は、先に 3.4.2 の手順で作ってから指定する
- タスクに届くのは、指定した SG（API の `tickets` の SG）からの TCP 8090 だけ。タスクから外へは 443 番だけ（ECR・S3・CloudWatch Logs）

タスクがイメージの取得（ECR・S3）とログの送信（CloudWatch Logs）に使う経路で、2つのパターンがある。

| パターン | 経路 | `CreateEndpoints` | 時間課金（東京の目安） |
|---|---|---|---|
| **エンドポイント**（セキュリティの観点で推奨） | このスタックが VPC エンドポイント（`ecr.api`・`ecr.dkr`・`logs`、1 AZ）と S3 のゲートウェイ型エンドポイントを作る。エンドポイントのポリシーで、このリポジトリの取得とこのロググループへの書き込みだけを許す | `true` | スタックがある間 約 $0.042/時間 |
| **NAT** | サブネットのルートテーブルに、既にある `0.0.0.0/0 → NAT ゲートウェイ` を使う（このスタックは何も作らない） | `false` | NAT がある間 約 $0.062/時間（3.4.2 で作った場合） |

- `CreateEndpoints=true` は、**スタブだけが使う VPC（3.4.2 で作るものなど）に限る**。エンドポイントのプライベート DNS とポリシーは VPC 全体（S3 はルートテーブル全体）に効くので、ほかのサービスがある既存の VPC で作ると、そのサービスの ECR・CloudWatch Logs・S3 の利用を止めてしまう。また、同じ VPC に同じサービスのエンドポイントが既にあると、作成に失敗する
- 既存の VPC に、ECR・Logs のエンドポイント（またはNAT）が既にある場合は `CreateEndpoints=false` にする。既存のエンドポイントの SG に、タスクの SG（スタックの出力 `TaskSecurityGroupId`）からの 443 を足してもらう

#### 3.4.1 前提と変数

```sh
export STUB_IMPL=node                    # node / python / rust（同じ動き）
export TICKETS_SG=sg-xxxxxxxx            # API の tickets に付ける SG（go/node DEPLOY.md 4-A.4 の LAMBDA_SG と同じもの）
export IMAGE_TAG=$(git rev-parse --short HEAD)$(git diff --quiet || echo -dirty-$(date +%s))
```

- スタブを置く VPC が `tickets` と別の VPC の場合は、VPC ピアリングでつなぐ（3.4.2 の手順 4）。同じリージョンのピアリングなら、`TICKETS_SG`（相手の VPC の SG）をスタブの SG の送信元に指定できる
- `tickets` の SG の送信ルールを絞っている場合は、スタブのサブネットへの TCP 8090 を許可しておく（既定の「送信はすべて許可」なら不要）

既存の VPC を使う場合は、次を設定して 3.4.3 へ進む。

```sh
export STUB_VPC_ID=vpc-xxxxxxxx          # 既存の VPC
export STUB_SUBNET_ID=subnet-xxxxxxxx    # 既存のプライベートサブネット（タスクを置く）
export STUB_RT_ID=rtb-xxxxxxxx           # そのサブネットのルートテーブル（CreateEndpoints=true のときに使う）
export CREATE_ENDPOINTS=false            # 既存の VPC では、通常 false（上の注意）
```

#### 3.4.2 （新規の場合）スタブ用の VPC を作る

VPC・サブネット・ルートテーブル・SG・インターネットゲートウェイ・ピアリングには時間課金がない。NAT ゲートウェイ（NAT のパターン）には時間課金がある。

1. VPC とプライベートサブネット（両パターン共通）

```sh
export STUB_VPC_CIDR=10.99.0.0/24              # tickets の VPC と重ならないもの
export STUB_PRIVATE_CIDR=10.99.0.0/26
export STUB_AZ=${AWS_REGION}a

export STUB_VPC_ID=$(aws ec2 create-vpc --cidr-block $STUB_VPC_CIDR \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=ticketqr-analyzer-stub}]' \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id $STUB_VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $STUB_VPC_ID --enable-dns-hostnames '{"Value":true}'   # エンドポイントのプライベート DNS に必要

export STUB_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $STUB_VPC_ID --cidr-block $STUB_PRIVATE_CIDR \
  --availability-zone $STUB_AZ \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ticketqr-analyzer-stub-private}]' \
  --query Subnet.SubnetId --output text)
export STUB_RT_ID=$(aws ec2 create-route-table --vpc-id $STUB_VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=ticketqr-analyzer-stub-private}]' \
  --query RouteTable.RouteTableId --output text)
aws ec2 associate-route-table --route-table-id $STUB_RT_ID --subnet-id $STUB_SUBNET_ID
```

2. エンドポイントのパターン: ここでは何も足さない（エンドポイントは 3.4.3 のスタックが作る）

```sh
export CREATE_ENDPOINTS=true
```

3. NAT のパターン: パブリックサブネット・インターネットゲートウェイ・NAT ゲートウェイを作り、プライベートサブネットの外向きを NAT に向ける

```sh
export CREATE_ENDPOINTS=false
export STUB_PUBLIC_CIDR=10.99.0.64/26

export STUB_IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $STUB_IGW_ID --vpc-id $STUB_VPC_ID

export STUB_PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $STUB_VPC_ID --cidr-block $STUB_PUBLIC_CIDR \
  --availability-zone $STUB_AZ \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ticketqr-analyzer-stub-public}]' \
  --query Subnet.SubnetId --output text)
export STUB_PUBLIC_RT_ID=$(aws ec2 create-route-table --vpc-id $STUB_VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=ticketqr-analyzer-stub-public}]' \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $STUB_PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $STUB_IGW_ID
aws ec2 associate-route-table --route-table-id $STUB_PUBLIC_RT_ID --subnet-id $STUB_PUBLIC_SUBNET_ID

export STUB_EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
export STUB_NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $STUB_PUBLIC_SUBNET_ID --allocation-id $STUB_EIP_ALLOC \
  --query NatGateway.NatGatewayId --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $STUB_NAT_ID          # 数分。ここから時間課金
aws ec2 create-route --route-table-id $STUB_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $STUB_NAT_ID
```

4. `tickets` の VPC とピアリングでつなぐ（両パターン共通。同じアカウント・同じリージョン）

```sh
export TICKETS_VPC_ID=vpc-xxxxxxxx               # tickets を置く既存の VPC
export TICKETS_SUBNET_CIDR_A=10.0.1.0/24         # tickets を置くサブネットの CIDR（go/node DEPLOY.md 4-A.4 の SUBNET_A）
export TICKETS_SUBNET_CIDR_B=10.0.2.0/24         # 同 SUBNET_B
export TICKETS_RT_ID=rtb-yyyyyyyy                # そのサブネットのルートテーブル（サブネットごとに違えば、それぞれに手順の最後の行を実行する）

export STUB_PCX_ID=$(aws ec2 create-vpc-peering-connection --vpc-id $STUB_VPC_ID --peer-vpc-id $TICKETS_VPC_ID \
  --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=ticketqr-analyzer-stub}]' \
  --query VpcPeeringConnection.VpcPeeringConnectionId --output text)
aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id $STUB_PCX_ID
aws ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids $STUB_PCX_ID

# スタブの VPC → tickets のサブネットだけ（既存の VPC 全体には向けない）
aws ec2 create-route --route-table-id $STUB_RT_ID --destination-cidr-block $TICKETS_SUBNET_CIDR_A --vpc-peering-connection-id $STUB_PCX_ID
aws ec2 create-route --route-table-id $STUB_RT_ID --destination-cidr-block $TICKETS_SUBNET_CIDR_B --vpc-peering-connection-id $STUB_PCX_ID
# 既存の VPC → スタブのプライベートサブネットだけ（既存の VPC の変更。持ち主の了承を得てから）
aws ec2 create-route --route-table-id $TICKETS_RT_ID --destination-cidr-block $STUB_PRIVATE_CIDR --vpc-peering-connection-id $STUB_PCX_ID
```

- ピアリングは双方向なので、既存の VPC にある SG（EC2・RDS など）が広い CIDR を許可していないか確かめる（notes/analyzer-stub-cost.md 5.7）

#### 3.4.3 スタックをデプロイする

```sh
aws cloudformation deploy --stack-name ticketqr-analyzer-stub-vpc-$STUB_IMPL \
  --template-file analyzer-stub/vpc-template.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Impl=$STUB_IMPL \
    VpcId=$STUB_VPC_ID \
    SubnetId=$STUB_SUBNET_ID \
    RouteTableId=$STUB_RT_ID \
    CreateEndpoints=$CREATE_ENDPOINTS \
    AllowedSourceSecurityGroupId=$TICKETS_SG \
    ImageTag=$IMAGE_TAG

export STUB_REPO_URI=$(aws cloudformation describe-stacks --stack-name ticketqr-analyzer-stub-vpc-$STUB_IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue" --output text)
export STUB_TASK_SG=$(aws cloudformation describe-stacks --stack-name ticketqr-analyzer-stub-vpc-$STUB_IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='TaskSecurityGroupId'].OutputValue" --output text)
```

- スタックが作るもの: ECR のリポジトリ、ロググループ、タスクの実行ロール、ECS のクラスターとタスク定義、タスクの SG、（`CreateEndpoints=true` のとき）エンドポイント4つとその SG。クラスターとタスク定義は、置いておいても課金されない
- `IMAGE_TAG` を変えたら（イメージを作り直したら）、このコマンドをもう一度実行してタスク定義を更新する

#### 3.4.4 イメージをビルドして ECR に置く

イメージはビルド済みで ECR に置き、タスクは起動時に依存を取得しない（エンドポイントのパターンでは、インターネットに出られないため）。

```sh
aws ecr get-login-password | docker login --username AWS --password-stdin ${STUB_REPO_URI%%/*}
docker build --platform linux/arm64 -t $STUB_REPO_URI:$IMAGE_TAG analyzer-stub/$STUB_IMPL   # Rust 版は初回 数分
docker push $STUB_REPO_URI:$IMAGE_TAG
```

#### 3.4.5 タスクを起動して、API をつなぐ（確認のたびに）

```sh
export STUB_TASK_ARN=$(aws ecs run-task --cluster ticketqr-analyzer-stub-$STUB_IMPL \
  --task-definition ticketqr-analyzer-stub-$STUB_IMPL --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$STUB_SUBNET_ID],securityGroups=[$STUB_TASK_SG],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-running --cluster ticketqr-analyzer-stub-$STUB_IMPL --tasks $STUB_TASK_ARN

export STUB_IP=$(aws ecs describe-tasks --cluster ticketqr-analyzer-stub-$STUB_IMPL --tasks $STUB_TASK_ARN \
  --query "tasks[0].attachments[0].details[?name=='privateIPv4Address'].value" --output text)
export ANALYZER_URL=http://$STUB_IP:8090/v1/analyze
echo $ANALYZER_URL
```

- 起動しないとき: `aws ecs describe-tasks --cluster ticketqr-analyzer-stub-$STUB_IMPL --tasks $STUB_TASK_ARN --query 'tasks[0].[lastStatus,stoppedReason,containers[0].reason]'`。`CannotPullContainerError` や `ResourceInitializationError` は、ECR・S3・Logs への経路（エンドポイント、その SG、NAT のルート）か、イメージのタグの誤り
- タスクの IP は起動のたびに変わる。続けて API をデプロイし直す: [go/DEPLOY.md](go/DEPLOY.md) / [node/DEPLOY.md](node/DEPLOY.md) の 4-A.4（手動は 4-B.4）を、`ANALYZER_URL` と、`LAMBDA_SG=$TICKETS_SG`、`tickets` のサブネットで実行する（API キーは指定しない）

#### 3.4.6 確認する

スタブはインターネットからも手元からも呼べない（`tickets` の SG からだけ）。API 経由で確かめる。

```sh
curl -s -F image=@testdata/images/photo.jpg $API_URL/v1/tickets/qr-inline | head -c 120; echo   # 201

# スタブが受け取った画像のハッシュが、送ったファイルと一致する（画像が加工されずに VPC をまたいで届いている）
shasum -a 256 testdata/images/photo.jpg
aws logs tail /ecs/ticketqr-analyzer-stub-$STUB_IMPL --since 10m   # 起動時の WARN（STUB_AUTH=none）と "analyzed" の行
```

- 502 / 504（`ANALYSIS_UPSTREAM_ERROR` / `ANALYSIS_TIMEOUT`）: `tickets` からスタブに届いていない。ピアリングのルート（両方向）、スタブの SG の送信元（`TICKETS_SG`）、`tickets` の SG の送信ルール、`ANALYZER_URL` の IP を確かめる

#### 3.4.7 止める・削除する

確認が終わったら、タスクを止める（止めればタスクの課金は 0）。

```sh
aws ecs stop-task --cluster ticketqr-analyzer-stub-$STUB_IMPL --task $STUB_TASK_ARN --query task.lastStatus --output text
```

使わなくなったら、API を `mock`（またはほかの接続先）に戻してから、スタックを削除する。エンドポイントのパターンは、スタックがある間エンドポイントの時間課金がかかるので、しばらく使わないなら削除しておく（作り直しは 3.4.3〜3.4.4）。

```sh
aws cloudformation delete-stack --stack-name ticketqr-analyzer-stub-vpc-$STUB_IMPL   # ECR のイメージも消える
aws cloudformation wait stack-delete-complete --stack-name ticketqr-analyzer-stub-vpc-$STUB_IMPL
```

3.4.2 で作った VPC を消す（作った順の逆。NAT のパターンの行は、NAT のパターンのときだけ）:

```sh
aws ec2 delete-route --route-table-id $TICKETS_RT_ID --destination-cidr-block $STUB_PRIVATE_CIDR   # 既存の VPC に足したルート
aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id $STUB_PCX_ID

aws ec2 delete-nat-gateway --nat-gateway-id $STUB_NAT_ID                                   # NAT のパターン
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $STUB_NAT_ID                            # NAT のパターン
aws ec2 release-address --allocation-id $STUB_EIP_ALLOC                                    # NAT のパターン
aws ec2 detach-internet-gateway --internet-gateway-id $STUB_IGW_ID --vpc-id $STUB_VPC_ID   # NAT のパターン
aws ec2 delete-internet-gateway --internet-gateway-id $STUB_IGW_ID                         # NAT のパターン
aws ec2 delete-subnet --subnet-id $STUB_PUBLIC_SUBNET_ID                                   # NAT のパターン
aws ec2 delete-route-table --route-table-id $STUB_PUBLIC_RT_ID                             # NAT のパターン

aws ec2 delete-subnet --subnet-id $STUB_SUBNET_ID
aws ec2 delete-route-table --route-table-id $STUB_RT_ID
aws ec2 delete-vpc --vpc-id $STUB_VPC_ID
```

- NAT のパターンで、しばらく使わないが VPC は残したい場合は、NAT ゲートウェイだけを消して（上の NAT の3行。ルート `0.0.0.0/0` は残るが行き先がなくなる）、使うときに 3.4.2 の手順 3 の NAT の部分を作り直す

## 4. まだ対応していないもの（今後、各手順書に追加する）

| 項目 | 状態 |
|---|---|
| `ALLOWED_ORIGINS`（Origin の照合） | 未実装（E2E.md 4.2）。実装したら、API の Lambda の環境変数を追加する（go / node） |
| HTTP API の CORS 設定のテンプレート化 | 今は web/DEPLOY.md 5章の `update-api` で設定する（スタックの外からの変更）。`api.yaml` に `AllowedOrigins` パラメータと `CorsConfiguration` を追加する |
| Web フロントエンドの独自ドメイン | CloudFront の代替ドメイン名と、us-east-1 の ACM 証明書を `web.yaml` に追加する。そのときは CORS の `AllowOrigins` も独自ドメインにする |
| API の独自ドメイン | `PublicBaseUrl` パラメータだけ用意してある。ACM 証明書と `AWS::ApiGatewayV2::DomainName`、`ApiMapping` は別途追加する |
| 本物の画像解析サーバーへの接続 | HTTP クライアントは Go 版・Node 版とも、仮のプロトコル（analyzer-stub/DESIGN.md 3）で実装済み。本物の仕様が決まったら、レスポンスの解釈部分（Go: `parseResponse`、Node: `parseAnalyzerResponse`）を差し替える。VPC の設定が必要になる可能性がある |
| WAF | HTTP API に直接は付けられない。手前に CloudFront を置く場合に検討する |
| GitHub Actions からのデプロイ | `github-template/workflows/deploy.yml` を定義済み（専用のリポジトリの `.github/` にコピーして使うテンプレート。未検証）。OIDC で IAM ロールを引き受け、各手順書の CloudFormation の手順を実行する。準備と流れは [CI.md](CI.md) 4章 |
