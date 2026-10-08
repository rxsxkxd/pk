# チケット QR API の SAM 定義（Lambda のビルドと配備）

ネットワークは事前に CloudFormation で作り（`infra/cloudformation/tickets-network-existing-vpc.yaml` か `tickets-network-new-vpc.yaml`。[../../notes/tickets-network.md](../../notes/tickets-network.md)）、**Lambda のビルドと登録（と API Gateway）だけを AWS SAM で行う**ための定義。既存の CloudFormation の定義（`infra/cloudformation/api.yaml`）はそのまま残してあり、SAM から生成した CloudFormation と見比べられるようにしている（4章）。

> 2026-10-08 作成。`sam build`（Go・Node）、`sam validate --lint`、cfn-lint、CloudFormation への変換と、変換結果の cfn-lint までを確認。AWS 上への `sam deploy` は未検証。

## 1. ファイル

| ファイル | 内容 |
|---|---|
| `go/template.yaml` | Go 版。`sam build` が `go/Makefile` の `build-TicketsFunction` / `build-GetQRFunction`（`make -C go build` と同じフラグ。arm64 の `bootstrap`）を実行する |
| `node/template.yaml` | Node 版。`sam build` が esbuild で `node/src/ticketqr.ts` をまとめる（`npm run build:ticketqr` と同じオプション。`ticketqr.mjs`、ハンドラーは `ticketqr.handler`） |
| `translate.py` | SAM の定義を、`sam deploy` が作るのと同じ CloudFormation に変換する（オフライン。AWS の認証は要らない） |
| `generated/go.cfn.yaml` / `generated/node.cfn.yaml` | `translate.py` の出力（見比べ用。`api.yaml` と同じ YAML の短い書き方（`!Sub`・`!Ref` など）。Lambda のコードの場所だけ、仮の S3 の場所 `s3://ARTIFACT_BUCKET/sam-placeholder/…`）。出力ファイルの拡張子を `.json` にすると JSON で出る |

実装（Go / Node）ごとにテンプレートを分けている。SAM はビルドの対象（`CodeUri`）と方法をパラメータで切り替えられないため（`api.yaml` は `Impl` で切り替える）。

## 2. 中身（`api.yaml` との対応）

| 対象 | SAM の定義 | `api.yaml` |
|---|---|---|
| Lambda（`tickets`・`get-qr`） | `AWS::Serverless::Function`。コードは `sam build` が作り、`sam deploy` が S3 に上げる | `AWS::Lambda::Function`。zip を自分で S3 に上げ、`ArtifactBucket`・`ArtifactPrefix` で指定する |
| `tickets` の VPC の設定 | **必須**（`VpcSubnetIds`・`VpcSecurityGroupIds`。ネットワークのスタックの出力 `PrivateSubnetIds`・`SecurityGroupId`） | 任意（空なら VPC の外） |
| 実行ロール | 関数ごとに SAM が作る（`TicketsFunctionRole`・`GetQRFunctionRole`）。`tickets` のロールにだけ `AWSLambdaVPCAccessExecutionRole` が付く | 2つの関数で1つのロール（VPC のときは両方に VPC の権限が付く） |
| API Gateway（HTTP API、`$default` ステージ、スロットリング、アクセスログ、統合、ルート、呼び出し権限） | `api.yaml` と同じリソース（`AWS::ApiGatewayV2::*`）をそのまま書く | 同左 |
| 名前 | 関数・API・ロググループの名前は `api.yaml`（`Impl=go` / `node`）と同じ | - |

API Gateway を SAM の `AWS::Serverless::HttpApi` と関数の `Events` で書かない理由: そうすると、API の定義に関数の ARN が入り、関数の環境変数 `PUBLIC_BASE_URL` が API を参照するため、**循環参照**になってデプロイできない（変換結果の cfn-lint で `E3004 Circular Dependencies` が出る）。`api.yaml` と同じく、統合とルートを別のリソースにして避けている。

## 3. ビルドとデプロイ

前提: SAM CLI（例: `uvx --from aws-sam-cli sam …`、またはインストール）、Go（Go 版）、Node.js 24 と `npm --prefix node ci` 済みの `node/node_modules`（Node 版）、署名の salt（go/node DEPLOY.md 3章）、ネットワークのスタック。

```sh
cd docs/st
export IMPL=go                                      # go / node
export SALT_PARAM=/ticketqr/$IMPL/signing-salt

# ネットワークのスタック（tickets-network-*.yaml）の出力
export TICKETS_SUBNETS=$(aws cloudformation describe-stacks --stack-name ticketqr-tickets-network \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetIds'].OutputValue" --output text)
export TICKETS_SG=$(aws cloudformation describe-stacks --stack-name ticketqr-tickets-network \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroupId'].OutputValue" --output text)

# ビルド（Go 版）
sam build --template-file infra/sam/go/template.yaml --build-dir infra/sam/go/.aws-sam/build
# ビルド（Node 版。SAM は本番用の依存しか入れないので、esbuild を PATH に置く）
PATH="$PWD/node/node_modules/.bin:$PATH" \
  sam build --template-file infra/sam/node/template.yaml --build-dir infra/sam/node/.aws-sam/build

# デプロイ（作成と更新は同じコマンド）
sam deploy --template-file infra/sam/$IMPL/.aws-sam/build/template.yaml \
  --stack-name ticketqr-sam-$IMPL \
  --s3-bucket $ARTIFACT_BUCKET --s3-prefix ticketqr-sam/$IMPL \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides \
    VpcSubnetIds=$TICKETS_SUBNETS \
    VpcSecurityGroupIds=$TICKETS_SG \
    SigningSaltParameterName=$SALT_PARAM

export API_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-sam-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
```

- 外の解析サーバーにつなぐときは、`--parameter-overrides` に `AnalyzerMode=http AnalyzerUrl=…`（API キーを使うなら `AnalyzerApiKeyParameterName=…`）を足す
- スタック名を `ticketqr-sam-$IMPL` にしているのは、`api.yaml` のスタック（`ticketqr-$IMPL`）と並べて試せるようにするため。ただし、関数・API・ロググループの**名前は `api.yaml` と同じ**なので、同じアカウント・リージョンに両方を同時に作ることはできない（どちらかを消してから作る）
- 変更内容を先に見たいときは、`sam deploy` に `--no-execute-changeset` を付ける
- 削除: `sam delete --stack-name ticketqr-sam-$IMPL --no-prompts`（ネットワークのスタックは、これを消した後に消す。Lambda の ENI が残っているとサブネットを消せない）

## 4. 生成される CloudFormation を見比べる

```sh
cd docs/st/infra/sam
uvx --with aws-sam-translator==1.113.0 --with pyyaml --with cfn-flip==1.3.0 python translate.py go/template.yaml generated/go.cfn.yaml
uvx --with aws-sam-translator==1.113.0 --with pyyaml --with cfn-flip==1.3.0 python translate.py node/template.yaml generated/node.cfn.yaml
uvx cfn-lint==1.57.1 --regions=ap-northeast-1 --ignore-checks E1161 -- generated/*.cfn.yaml   # E1161: 仮の S3 バケット名
```

- 出力の形式は拡張子で決まる（`.yaml` は YAML の短い書き方、`.json` は JSON）。SAM の変換そのものは形式に関係しない（SAM CLI 自体には、変換結果をファイルに書き出すコマンドはない）
- `sam deploy` が実際に作るものは、AWS の上での同じ変換の結果（`aws cloudformation get-template --stack-name ticketqr-sam-$IMPL --template-stage Processed` で取り出せる。こちらは JSON で返る）。オフラインの変換とは、リージョンによる ARN の区分（`arn:aws:`）などが違うことがある
- 見比べるときの主な違い（2章）: 関数ごとの実行ロール（`TicketsFunctionRole`・`GetQRFunctionRole`）、関数のタグ `lambda:createdBy: SAM`、コードの場所（`sam deploy` が上げたもの）、`Impl` のパラメータとマッピングがないこと、VPC の設定が必須なこと
