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
   - 外部の解析サーバー（送信元の IP で許可、API キーなし）に近い形で確かめる場合は、Fargate のスタブ（3.4。パブリックサブネットに置き、許可した IP からだけ呼べる）を使う。API からスタブまでの経路（`tickets` を VPC に置くか、NAT など）は未確定

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

### 3.2 スタブをデプロイする（初回、またはスタブを更新するとき。AWS SAM）

> Lambda 版のスタブは、今後使わない可能性が高い（VPC 内のスタブ（3.4）を使う見込み）。SAM のテンプレートは、`sam validate --lint` と cfn-lint だけを確かめていて、AWS 上へのデプロイは未検証。

テンプレートは AWS SAM（`analyzer-stub/template.yaml`）。選んだ実装のビルドで作った zip を `analyzer-stub/dist/analyzer-stub.zip` にコピーし、`sam deploy` がそれを成果物バケットに上げてからスタックを作る（`Impl` でランタイムとハンドラーを切り替える。zip と `Impl` は同じ実装にそろえる）。SAM CLI が要る（例: `uvx --from aws-sam-cli sam …`、または SAM CLI をインストールする）。

```sh
# 1. 選んだ実装をビルドし、zip を共通の置き場所にコピーする（どれか1つ）
npm --prefix analyzer-stub/node run build && mkdir -p analyzer-stub/dist && cp analyzer-stub/node/dist/analyzer-stub.zip analyzer-stub/dist/
# analyzer-stub/python/build.sh && mkdir -p analyzer-stub/dist && cp analyzer-stub/python/dist/analyzer-stub.zip analyzer-stub/dist/
# analyzer-stub/rust/build.sh && mkdir -p analyzer-stub/dist && cp analyzer-stub/rust/dist/analyzer-stub.zip analyzer-stub/dist/

# 2. デプロイする（作成と更新は同じコマンド）
sam deploy --template-file analyzer-stub/template.yaml \
  --stack-name ticketqr-analyzer-stub-$STUB_IMPL \
  --s3-bucket $ARTIFACT_BUCKET --s3-prefix analyzer-stub/$STUB_IMPL \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides Impl=$STUB_IMPL ApiKeyParameterName=$ANALYZER_KEY_PARAM

export ANALYZER_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-analyzer-stub-$STUB_IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='AnalyzeUrl'].OutputValue" --output text)
echo $ANALYZER_URL
```

- `sam deploy` は、zip の中身が変わったときだけ新しいキーで上げ直すので、`ArtifactPrefix` のような接頭辞の管理は要らない
- テンプレートの確認だけなら `sam validate --lint --template-file analyzer-stub/template.yaml`

スタブを直接 curl で叩くときは、`aws ssm get-parameter --name $ANALYZER_KEY_PARAM --with-decryption --query Parameter.Value --output text` で API キーの値を取り出す。

この後、API を `http` モードに切り替える: [go/DEPLOY.md](go/DEPLOY.md) / [node/DEPLOY.md](node/DEPLOY.md) の 4-A.3（手動は 4-B.3。`ANALYZER_URL`・`ANALYZER_KEY_PARAM`・`STUB_IMPL` を使う）。

### 3.3 スタブを削除する

API を `mock` に戻してから削除する（`http` のまま削除すると、発行の API がすべて 502 になる）。

```sh
sam delete --stack-name ticketqr-analyzer-stub-$STUB_IMPL --no-prompts
aws ssm delete-parameter --name $ANALYZER_KEY_PARAM   # API キーはスタックの外にあるので別に削除する
```

### 3.4 Fargate のスタブ（パブリックサブネット、外部から呼べる。任意）

スタブを ECS Fargate のタスクとして、スタブ用の VPC の**パブリックサブネット**に置き、**インターネットから**呼べるようにする。受信は、指定した送信元の IP の範囲（CIDR）だけに絞る。3.1〜3.3（Lambda + Function URL）とは別のもので、API キーは使わない（`STUB_AUTH=none`）。

- 本物の解析サーバーの構成は未確定。AWS の外にあり、送信元の IP（利用側の NAT ゲートウェイの固定 IP など）で許可しているだけの可能性もある。そのため、このスタブは「外部から、許可した IP からだけ呼べるサーバー」として用意し、**API の `tickets` からスタブまでの経路（VPC に置くか、NAT、ピアリングなど）は決めない**（3.4.4）
- スタブは、コンテナ（各実装のローカル用サーバー。`analyzer-stub/{node,python,rust}/Dockerfile`）を、**確認のときだけ**起動する（`aws ecs run-task`）。止めればタスクの課金は 0
- 受信は TCP 8090 を `AllowedSourceCidr`（と `AllowedSourceCidrB`）からだけ。送信は 443 番だけ（ECR・S3・CloudWatch Logs）

| 作るもの | 中身 | 時間課金（東京の目安） |
|---|---|---|
| `analyzer-stub/network.yaml`（CloudFormation） | スタブ用の VPC、パブリックサブネット、インターネットゲートウェイ、ルート、タスクの SG | なし |
| `analyzer-stub/cdk/`（AWS CDK、Python） | コンテナイメージ（ビルドと push）、ECS のクラスターとタスク定義、タスクの実行ロール、ロググループ | なし（置いておくだけなら） |
| タスク（`run-task`） | 確認のときだけ起動 | 動かす間だけ 約 $0.015/時間（タスク + パブリック IPv4） |

注意:
- **スタブは API キーなしで、HTTP（暗号化なし）で受け付ける**。`AllowedSourceCidr` に `0.0.0.0/0` を指定すると、インターネットの誰からでも呼べる。できるだけ狭い範囲（`tickets` 側の NAT の固定 IP `/32`、確認する人の IP など）にし、テスト用の画像だけを使い、確認が終わったらタスクを止める
- タスクのパブリック IP は起動のたびに変わる（Fargate のタスクには Elastic IP を付けられない）。起動のたびに、API の接続先（`ANALYZER_URL`）を更新する
- 組織のルールでパブリック IP が使えない場合は、相談する（CDK はプライベートサブネットと VPC エンドポイントにも対応しているが、手順は用意していない。notes/analyzer-stub-cost.md 5章）

#### 3.4.1 前提と変数

```sh
export STUB_IMPL=node                      # node / python / rust（同じ動き）
export STUB_ALLOWED_CIDR=203.0.113.10/32   # スタブを呼んでよい送信元（例: tickets 側の NAT の固定 IP、確認する人の IP）
export STUB_ALLOWED_CIDR_B=                # 2つめ（任意）
```

#### 3.4.2 スタブ用のネットワークを作る（CloudFormation）

```sh
aws cloudformation deploy --stack-name ticketqr-analyzer-stub-network \
  --template-file analyzer-stub/network.yaml \
  --parameter-overrides \
    VpcCidr=10.99.0.0/24 \
    PublicSubnetCidr=10.99.0.0/26 \
    AllowedSourceCidr=$STUB_ALLOWED_CIDR \
    AllowedSourceCidrB=$STUB_ALLOWED_CIDR_B

export STUB_VPC_ID=$(aws cloudformation describe-stacks --stack-name ticketqr-analyzer-stub-network \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)
export STUB_SUBNET_ID=$(aws cloudformation describe-stacks --stack-name ticketqr-analyzer-stub-network \
  --query "Stacks[0].Outputs[?OutputKey=='SubnetId'].OutputValue" --output text)
export STUB_TASK_SG=$(aws cloudformation describe-stacks --stack-name ticketqr-analyzer-stub-network \
  --query "Stacks[0].Outputs[?OutputKey=='TaskSecurityGroupId'].OutputValue" --output text)
```

- 既存の VPC やサービスには何も変更しない（新しい VPC の中だけ）
- 許可する送信元を変えるときは、`AllowedSourceCidr` を変えてこのコマンドをもう一度実行する（動いているタスクにもすぐ効く）

#### 3.4.3 スタブをデプロイする（CDK。イメージのビルドを含む）

`cdk deploy` が、`analyzer-stub/$STUB_IMPL/Dockerfile` からイメージを arm64 でビルドし、ECR（CDK のブートストラップのリポジトリ）に push してから、ECS のクラスターとタスク定義などを作る。VPC・サブネット・SG は 3.4.2 のものを `-c` で指定する。

前提（初回だけ）:
- Docker（arm64 のイメージをビルドする。Apple シリコンの Mac ならそのまま、x86 の PC では QEMU / buildx が要る）、Python 3.13 以降、Node.js（CDK の CLI を `npx` で動かす）
- アカウントとリージョンごとに1回、CDK のブートストラップ

```sh
python3 -m venv analyzer-stub/cdk/.venv
analyzer-stub/cdk/.venv/bin/pip install -r analyzer-stub/cdk/requirements.txt
npx -y aws-cdk@2.1145.0 bootstrap aws://$ACCOUNT_ID/$AWS_REGION   # アカウント・リージョンごとに1回
```

デプロイ（作成と更新は同じコマンド。スタブのコードを変えたときも、これだけでイメージを作り直して反映する）:

```sh
cd analyzer-stub/cdk
npx -y aws-cdk@2.1145.0 deploy --require-approval never \
  -c impl=$STUB_IMPL \
  -c vpcId=$STUB_VPC_ID \
  -c subnetId=$STUB_SUBNET_ID \
  -c taskSecurityGroupId=$STUB_TASK_SG
cd ../..
```

- スタック名は `ticketqr-analyzer-stub-vpc-$STUB_IMPL`（実装ごとに1つ）
- 作るもの: ECS のクラスターとタスク定義（0.25 vCPU / 0.5GB、arm64、`STUB_AUTH=none`、読み取り専用のルートファイルシステム）、タスクの実行ロール、ロググループ（`/ecs/ticketqr-analyzer-stub-$STUB_IMPL`、7日）。クラスターとタスク定義は、置いておいても課金されない
- 指定を誤ると、`cdk deploy` の前にエラーで止まる（必須の値がない、ID の形が違う、など）。変更内容を先に見たいときは `deploy` の代わりに `diff`（同じ `-c` を付ける）
- イメージは CDK のブートストラップの ECR のリポジトリに置かれる（スタックを消しても残る）

#### 3.4.4 タスクを起動する（確認のたびに）

```sh
export STUB_TASK_ARN=$(aws ecs run-task --cluster ticketqr-analyzer-stub-$STUB_IMPL \
  --task-definition ticketqr-analyzer-stub-$STUB_IMPL --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$STUB_SUBNET_ID],securityGroups=[$STUB_TASK_SG],assignPublicIp=ENABLED}" \
  --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-running --cluster ticketqr-analyzer-stub-$STUB_IMPL --tasks $STUB_TASK_ARN

STUB_ENI=$(aws ecs describe-tasks --cluster ticketqr-analyzer-stub-$STUB_IMPL --tasks $STUB_TASK_ARN \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)
export STUB_PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $STUB_ENI \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
export ANALYZER_URL=http://$STUB_PUBLIC_IP:8090/v1/analyze
echo $ANALYZER_URL
```

- `assignPublicIp=ENABLED` は必須（パブリック IP がないと、外部から呼べず、イメージも取得できない）
- 起動しないとき: `aws ecs describe-tasks --cluster ticketqr-analyzer-stub-$STUB_IMPL --tasks $STUB_TASK_ARN --query 'tasks[0].[lastStatus,stoppedReason,containers[0].reason]'`
- **API（`tickets`）からスタブまでの経路は、ここでは決めない**。参考:

| `tickets` の置き方 | スタブから見える送信元 | `AllowedSourceCidr` |
|---|---|---|
| VPC の外（今の既定） | Lambda の共有の IP（固定できない） | 固定の IP では絞れない（`0.0.0.0/0` などの広い範囲になる） |
| VPC のプライベートサブネット + NAT ゲートウェイ（固定の Elastic IP） | NAT の固定 IP | その IP の `/32`（本物の解析サーバーが「利用側の NAT の固定 IP で許可」している場合と同じ形） |

  API を `http` モードにして、`ANALYZER_URL` をスタブに向ける手順は、go/node DEPLOY.md の 4-A.3（API キーは指定しない）。`tickets` を VPC に置く場合は 4-A.4

#### 3.4.5 確認する

許可した送信元（`STUB_ALLOWED_CIDR` に入れた手元の IP など）から、スタブを直接呼べる。

```sh
curl -sS -X POST -H 'content-type: application/octet-stream' --data-binary @testdata/images/photo.jpg $ANALYZER_URL; echo
# → {"confidence":1,"detected":"stub","reason":"stub: no analysis","result":"PASS","status":200}

# スタブが受け取った画像のハッシュが、送ったファイルと一致する（画像が加工されずに届いている）
shasum -a 256 testdata/images/photo.jpg
aws logs tail /ecs/ticketqr-analyzer-stub-$STUB_IMPL --since 10m   # 起動時の WARN（STUB_AUTH=none）と "analyzed" の行
```

- 許可していない送信元からは、接続がタイムアウトする（SG が捨てる）
- API 経由で確かめる場合は、API の `ANALYZER_URL` をスタブに向けたうえで、`curl -s -F image=@testdata/images/photo.jpg $API_URL/v1/tickets/qr-inline`（201）。502 / 504 なら、`tickets` からスタブに届いていない（送信元の IP が `AllowedSourceCidr` に入っているか、`ANALYZER_URL` の IP が今のタスクのものか）

#### 3.4.6 止める・削除する

確認が終わったら、タスクを止める（止めればタスクの課金は 0。パブリック IP も消える）。

```sh
aws ecs stop-task --cluster ticketqr-analyzer-stub-$STUB_IMPL --task $STUB_TASK_ARN --query task.lastStatus --output text
```

使わなくなったら、API の接続先をほかに戻してから、スタブのスタック、ネットワークのスタックの順に削除する（どちらも、置いておくだけなら時間課金はない）。

```sh
cd analyzer-stub/cdk
npx -y aws-cdk@2.1145.0 destroy --force -c impl=$STUB_IMPL -c vpcId=$STUB_VPC_ID -c subnetId=$STUB_SUBNET_ID \
  -c taskSecurityGroupId=$STUB_TASK_SG
cd ../..
aws cloudformation delete-stack --stack-name ticketqr-analyzer-stub-network
aws cloudformation wait stack-delete-complete --stack-name ticketqr-analyzer-stub-network
```

- `destroy` にも、スタック名を決めるために `deploy` と同じ `-c` が要る（`aws cloudformation delete-stack --stack-name ticketqr-analyzer-stub-vpc-$STUB_IMPL` でも消せる）

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
