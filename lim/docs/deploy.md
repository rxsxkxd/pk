# AWS へのデプロイ

AWS SAM で実際の AWS アカウントに構築する手順。
定義は [`template.yml`](../template.yml)、設定は [`samconfig.toml`](../samconfig.toml)。

```
make test → make validate → make deploy → 確認メールのリンクを押す → 原本を S3 に置く → API に POST → 出力を S3 から取り出して確認
```

**デプロイの前に、ローカルで確認しておくとつまずきが減る。**

| 段階 | 手順書 | 必要なもの |
|---|---|---|
| 1. 画像処理の確認 | [test-local.md](test-local.md) | Go だけ |
| 2. イベントと配線の確認 | [test-sam-local.md](test-sam-local.md) | Docker + AWS 認証情報 |
| 3. **AWS へ反映**（この文書） | — | AWS 認証情報 + 権限 |

設計の詳細は [image-blur-lambda-design.md](image-blur-lambda-design.md) を参照。

---

## 1. 必要なもの

| | 確認コマンド |
|---|---|
| AWS CLI（認証情報の設定済み） | `aws sts get-caller-identity` |
| AWS SAM CLI | `sam --version` |
| Go 1.24 以降 | `go version` |

デプロイする IAM 主体には、Lambda / API Gateway / SNS / CloudWatch / IAM ロール作成の権限が要る。

**原本とマスク済みを置く S3 バケットは既存のものを使う。** このテンプレートはバケットを作らない。
バケットは Lambda と**同じ AWS アカウント**にある前提（別アカウントの場合は §8 を参照）。

---

## 2. 初回デプロイ

```bash
make test      # 先にテストを通す
make validate  # テンプレートの検証（sam validate --lint 相当）
make deploy    # ビルドしてデプロイ
```

スタック名・リージョン・パラメータは **`samconfig.toml`** に書いてあるので、対話は
変更内容の確認だけ。`--guided` は不要。

```toml
[default.global.parameters]
stack_name = "image-mask-dev"

[default.deploy.parameters]
region = "ap-northeast-1"
capabilities = "CAPABILITY_IAM"   # Lambda の実行ロールを作るため必須
confirm_changeset = true
resolve_s3 = true                 # デプロイ用バケットは SAM に任せる
parameter_overrides = "Env=\"dev\""
```

### 既存のバケットを指定する（必須）

`samconfig.toml` の `BucketName` を、実際に使うバケット名に書き換える。

```toml
parameter_overrides = "Env=\"dev\" BucketName=\"REPLACE_WITH_EXISTING_BUCKET\""
#                                             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ここ
```

書き換えないままデプロイすると、名前の形式チェックで止まる（誤ったバケットへ向けないため）。

```
Parameter BucketName failed to satisfy constraint: 既存の S3 バケット名を指定してください
```

バケットがカスタマー管理の KMS キーで暗号化されている場合は、`BucketKmsKeyArn` も足す。

```toml
parameter_overrides = "Env=\"dev\" BucketName=\"my-bucket\" BucketKmsKeyArn=\"arn:aws:kms:ap-northeast-1:123456789012:key/xxxx\""
```

SSE-S3 や AWS 管理キー（`aws/s3`）で暗号化されている場合は不要。

環境は `dev`（既定）・`stg`・`prod` の 3 つを用意してある。

```bash
make deploy            # dev
make deploy ENV=prod   # prod
```

### 通知メールを設定する

`AlertEmail` は `samconfig.toml` に書いていない（リポジトリに個人のアドレスを
入れないため）。使うときはコマンドラインで渡すか、手元の `samconfig.toml` に足す。

```bash
sam deploy --parameter-overrides 'Env="dev" AlertEmail="you@example.com"'
```

### 作られるもの

| | |
|---|---|
| Lambda 関数 | `image-mask-<Env>` |
| API Gateway（HTTP API） | `POST /mask`。IAM 認証 |
| SNS トピック | アラートの通知先 |
| CloudWatch アラーム | 4 種 |

**S3 バケットと KMS キーは作られない。** 既存のバケットを `BucketName` で指定する。

デプロイが終わると Outputs に `ApiEndpoint` / `BucketName` / `FunctionName` などが出る。

---

## 3. デプロイ直後にやること

**`AlertEmail` を指定した場合、Amazon SNS からそのアドレスにサブスクリプションの
確認メールが届く。リンクを押して確認するまで通知は来ない。**
CloudFormation はこの承認を代行できず、未承認でもスタックの作成は成功してしまう。

```bash
STACK=image-mask-dev
TOPIC=$(aws cloudformation describe-stacks --stack-name $STACK \
  --query 'Stacks[0].Outputs[?OutputKey==`AlertTopicArn`].OutputValue' --output text)

aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" \
  --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
```

`SubscriptionArn` が `PendingConfirmation` なら未承認。

---

## 4. 動作確認

```bash
STACK=image-mask-dev
BUCKET=$(aws cloudformation describe-stacks --stack-name $STACK \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' --output text)
API=$(aws cloudformation describe-stacks --stack-name $STACK \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' --output text)

# テスト用の画像（実写真を使わなくてよい）
make sample

# 原本を置く。KeyPrefix を設定した場合はキーの先頭にその階層を足す
aws s3 cp testdata/idcard.jpg \
  "s3://$BUCKET/t-001/no-masked/2026-09-14/loc-12/e-98765"

# API に POST する（IAM 認証なので SigV4 で署名する）
eval "$(aws configure export-credentials --format env)"   # SSO/プロファイルでも環境変数に出す
curl -sS -X POST "$API" \
  --aws-sigv4 "aws:amz:$(aws configure get region):execute-api" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  -H "x-amz-security-token: $AWS_SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d @events/request.json

# 結果を取り出して目で見る
aws s3 cp "s3://$BUCKET/t-001/masked/2026-09-14/loc-12/e-98765" tmp/masked.jpg
```

`curl` の `--aws-sigv4` は curl 7.75 以降で使える。署名しないと **403** が返る。

期待する応答:

```json
{"sourceKey":"t-001/no-masked/2026-09-14/loc-12/e-98765",
 "outputKey":"t-001/masked/2026-09-14/loc-12/e-98765",
 "skipped":false,"radiusPx":36,"strengthScore":1.15}
```

もう一度同じ呼び出しをすると `"skipped":true` が返る（冪等）。

### 応答の HTTP ステータス

| ステータス | 意味 |
|---|---|
| 200 | 処理した、または処理済みだった |
| 400 | 本文が JSON でない、変数が不正 |
| 403 | 署名していない、または `execute-api:Invoke` の権限がない |
| 404 | 原本が存在しない |
| 500 | サーバー側の問題（強度検査の不合格、S3 の一時エラーなど）。CloudWatch アラームからメールが届く |

API Gateway 経由は同期呼び出しなので、**Lambda による自動リトライはない**。

### 呼び出し側に権限を与える

別の IAM ロールやユーザーから呼ばせる場合、次のポリシーを付ける。
`Resource` は Outputs の `ApiInvokeArn` の値。

```json
{
  "Effect": "Allow",
  "Action": "execute-api:Invoke",
  "Resource": "arn:aws:execute-api:ap-northeast-1:<アカウントID>:<api-id>/*/POST/mask"
}
```

### Lambda を直接呼ぶ場合

API Gateway を通さずに確認したいとき。

```bash
FUNC=$(aws cloudformation describe-stacks --stack-name $STACK \
  --query 'Stacks[0].Outputs[?OutputKey==`FunctionName`].OutputValue' --output text)
aws lambda invoke --function-name "$FUNC" --payload file://events/request.json \
  --cli-binary-format raw-in-base64-out tmp/out.json && cat tmp/out.json
```

### ログを見る

```bash
sam logs --stack-name image-mask-dev --tail
```

### 失敗したとき

エラーの分類（`validation` / `strength` / 一時エラー）はログに出る。
再処理は同じリクエストを投げ直せばよい（§6 の「失敗した入力の再処理」と同じ）。

## 5. 2 回目以降

```bash
make deploy    # samconfig.toml があるので対話は最小限
```

コードだけ変えた場合も同じ。`sam build` がバイナリを作り直す。

---

## 6. 設定を変える

パラメータだけ変えたい場合:

```bash
sam deploy --parameter-overrides MaskHeightRatio=0.6 DownscaleFactor=1
```

**マスクの強度に関わる設定（`MaskHeightRatio` / `BlurRatio` / `DownscaleFactor`）を変えたときは、
`MaskingPolicyVersion` も上げる。** 上げないと、処理済みの画像は古い強度のまま残る。

```bash
sam deploy --parameter-overrides BlurRatio=0.06 MaskingPolicyVersion=v2
```

版を上げると、再投入したときに同じキーが新しい強度で上書きされる。

### S3 イベント通知で起動したい場合

既存のバケットはこのスタックの管理外なので、**イベント通知の設定はテンプレートでは行えない。**
次の 2 段階になる。

**1. S3 から Lambda を呼ぶ許可を作る**

```bash
sam deploy --parameter-overrides 'Env="dev" BucketName="my-bucket" EnableS3Trigger="true"'
```

**2. バケット側でイベント通知を設定する**

コンソールの「プロパティ → イベント通知」から追加するのが安全。

| 項目 | 値 |
|---|---|
| イベントタイプ | `s3:ObjectCreated:*` |
| プレフィックス | `KeyPrefix` を指定していれば `<KeyPrefix>/`、なければ空 |
| 送信先 | Lambda 関数 `image-mask-<Env>` |

> **`aws s3api put-bucket-notification-configuration` を使う場合は注意。** このコマンドは
> バケットのイベント通知設定を**丸ごと置き換える**。共有バケットで他の通知が
> 設定されていると消えてしまう。先に `get-bucket-notification-configuration` で
> 既存の設定を取得し、そこに追記したものを渡すこと。

マスク済みの書き込みでもイベント通知は飛ぶが、Lambda が infix を見て無視するため
無限ループにはならない。

## 7. 削除

```bash
sam delete --stack-name image-mask-dev
```

**バケットと中の画像は消えない。** バケットはこのスタックの管理外のため。
S3 イベント通知をバケット側に設定していた場合は、先にそちらを外しておく
（送信先の Lambda が無くなり、アップロード時にエラーになるわけではないが、無効な設定が残る）。

---

## 8. つまずきやすい点

| 症状 | 原因と対処 |
|---|---|
| `CAPABILITY_IAM` を求められる | Lambda の実行ロールを作るため。`--capabilities CAPABILITY_IAM` を付けるか、guided で `y` |
| API が 403 を返す | SigV4 で署名していない、または呼び出し側に `execute-api:Invoke` の権限がない |
| API が 503 / タイムアウトする | HTTP API の統合タイムアウトは 30 秒が上限。巨大な画像で超えることがある |
| CloudWatch アラームは鳴るがメールが来ない | Amazon SNS のサブスクリプションが未確認（→ 3.） |
| デプロイが `Parameter BucketName failed to satisfy constraint` で止まる | `samconfig.toml` の `BucketName` がプレースホルダーのまま（→ 2.） |
| 処理が `AccessDenied` で失敗する（S3 の権限は付いている） | バケットがカスタマー管理の KMS キーで暗号化されている。`BucketKmsKeyArn` を指定する。キーポリシーが IAM での許可を委任していない場合は、キーポリシー側に Lambda の実行ロールを足す |
| 処理が `AccessDenied` で失敗する（KMS も問題ない） | 既存のバケットポリシーに、Lambda に当てはまる明示的な `Deny`（特定の VPC エンドポイント以外を拒否、など）がある。バケットの管理者に確認する |
| バケットが別の AWS アカウントにある | IAM ポリシーだけでは足りない。**バケット側のバケットポリシーで Lambda の実行ロールを許可する**必要がある（KMS キーも同様） |
| 原本を置いても何も起きない | `EnableS3Trigger` の既定は `false`。API か直接呼び出しで処理する。S3 イベント通知を使うなら §6 の 2 段階を行う |
| 処理されず「レイアウトに合わない」とログに出る | キーの形が `[<prefix>/]<tid>/<infix>/<date>/<lid>/<eid>` と一致していない。`KeyPrefix` の設定と実際のキーを突き合わせる |

---

## 検証状況

| | |
|---|---|
| `sam validate --lint` | **通過済み** |
| `sam build` | **成功**（arm64 の Linux バイナリが `.aws-sam/build/MaskFunction/bootstrap` に出る） |
| `sam deploy` | **未実行**。AWS アカウントへの反映は確認していない |

デプロイで失敗したら内容を共有してほしい。
