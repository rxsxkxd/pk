# AWS へのデプロイ

AWS SAM で実際の AWS アカウントに構築する手順。
定義は [`template.yml`](../template.yml)、設定は [`samconfig.toml`](../samconfig.toml)。

```
make test → make validate → make deploy → 確認メールのリンクを押す → 原本を S3 に置く → aws lambda invoke → 出力を S3 から取り出して確認
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

デプロイする IAM 主体には、Lambda / S3 / KMS / SNS / CloudWatch / IAM ロール作成の権限が要る。

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
| S3 バケット | `image-mask-<Env>-<アカウントID>`（原本とマスク済みを同じバケットに置く） |
| Lambda 関数 | `image-mask-<Env>` |
| KMS キー | バケットの暗号化用 |
| SNS トピック | アラートの通知先 |
| CloudWatch アラーム | 4 種 |

デプロイが終わると Outputs に `ImageBucketName` / `FunctionName` / `OriginalKeyPattern` などが出る。

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
  --query 'Stacks[0].Outputs[?OutputKey==`ImageBucketName`].OutputValue' --output text)
FUNC=$(aws cloudformation describe-stacks --stack-name $STACK \
  --query 'Stacks[0].Outputs[?OutputKey==`FunctionName`].OutputValue' --output text)

# テスト用の画像（実写真を使わなくてよい）
make sample

# 原本を置く。KeyPrefix を設定した場合はキーの先頭にその階層を足す
aws s3 cp testdata/idcard.jpg \
  "s3://$BUCKET/t-001/no-masked/2026-09-14/loc-12/e-98765"

# 変数を渡して起動
aws lambda invoke --function-name "$FUNC" --payload '{
  "tenant_id": "t-001", "date": "2026-09-14",
  "location_id": "loc-12", "entry_id": "e-98765"
}' --cli-binary-format raw-in-base64-out tmp/out.json && cat tmp/out.json

# 結果を取り出して目で見る
aws s3 cp "s3://$BUCKET/t-001/masked/2026-09-14/loc-12/e-98765" tmp/masked.jpg
```

期待する応答:

```json
{"sourceKey":"t-001/no-masked/2026-09-14/loc-12/e-98765",
 "outputKey":"t-001/masked/2026-09-14/loc-12/e-98765",
 "skipped":false,"radiusPx":36,"strengthScore":1.15}
```

もう一度同じ呼び出しをすると `"skipped":true` が返る（冪等）。

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

```bash
sam deploy --parameter-overrides 'Env="dev" EnableS3Trigger="true"'
```

原本を置くだけで処理が走るようになる。

**この更新は 1 回目が失敗することがある。**

```
Unable to validate the following destination configurations
```

S3 はイベント通知の設定を受け付けるときに Lambda を呼べるか検証するが、その許可
（`AWS::Lambda::Permission`）も同じ更新で新規作成されるため、順序によっては
検証が先に走ってしまう。**もう一度同じコマンドを実行すれば通る**（許可は作成済みになる）。

許可リソースは `EnableS3Trigger=true` のときだけ作られる。無効な間は、S3 がこの関数を
呼ぶ権限そのものが存在しない。注意点は設計書 §6.1.1 と §8.2 を参照。

---

## 7. 削除

```bash
sam delete --stack-name image-mask-dev
```

**バケットの中身が残っていると削除に失敗する。** 先に空にする。

```bash
aws s3 rm "s3://$BUCKET" --recursive
# バージョニングを有効にしているため、古いバージョンも消す必要がある
```

---

## 8. つまずきやすい点

| 症状 | 原因と対処 |
|---|---|
| `CAPABILITY_IAM` を求められる | Lambda の実行ロールを作るため。`--capabilities CAPABILITY_IAM` を付けるか、guided で `y` |
| CloudWatch アラームは鳴るがメールが来ない | Amazon SNS のサブスクリプションが未確認（→ 3.） |
| 原本を置いても何も起きない | `EnableS3Trigger` の既定は `false`。リクエスト起動で呼ぶか、`true` にする |
| `EnableS3Trigger=true` にしたら `Unable to validate the following destination configurations` | S3 からの起動許可が同じ更新で作られるため、順序によっては検証が先に走る。**もう一度デプロイすれば通る** |
| 処理されず「レイアウトに合わない」とログに出る | キーの形が `[<prefix>/]<tid>/<infix>/<date>/<lid>/<eid>` と一致していない。`KeyPrefix` の設定と実際のキーを突き合わせる |
| バケット名が衝突する | 名前に AWS アカウント ID が入るので通常は衝突しない。同一アカウントで複数環境なら `Env` を変える |
| 既存のバケットを使いたい | **現在のテンプレートはバケットを新規作成する。** 既存バケットを使う構成には未対応で、テンプレートの修正が要る |
| `Circular dependency between resources` と言われる | バケットのイベント通知設定が Lambda を参照し、Lambda の IAM がバケットを参照すると閉路になる。**解消済み**（IAM とアクセス許可の ARN はバケット名から組み立てている）。テンプレートを編集して `!GetAtt ImageBucket.Arn` を Lambda 側に書くと再発する |
| バケット名を変えたい | 名前は `BucketName` のほか、Lambda の環境変数と IAM の ARN にも同じ式で書いてある（循環参照を避けるため）。`image-mask-${Env}-${AWS::AccountId}` を検索して全箇所を直す |

---

## 検証状況

| | |
|---|---|
| `sam validate --lint` | **通過済み** |
| `sam build` | **成功**（arm64 の Linux バイナリが `.aws-sam/build/MaskFunction/bootstrap` に出る） |
| `sam deploy` | **未実行**。AWS アカウントへの反映は確認していない |

デプロイで失敗したら内容を共有してほしい。
