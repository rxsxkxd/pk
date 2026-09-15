# SAM 経由のローカルテスト

Lambda と同じ実行環境（コンテナ）で関数を動かし、**イベントの形・環境変数・ハンドラの
配線**を確認する手順。

```
make build → events/env.json のバケット名を書き換え → 原本を S3 に置く → sam local invoke → 出力を S3 から取り出して確認
```

| 確認できること | イベントの解釈、環境変数の読み込み、ハンドラの分岐、S3 との実通信、応答の形 |
|---|---|
| **確認できないこと** | S3 イベント通知の配線、IAM の最小権限、リトライ、CloudWatch アラーム（→ [deploy.md](deploy.md)） |

---

## 重要な前提

**`sam local` はオフラインではない。** 関数の中の S3 呼び出しは**実際の AWS へ出る**。

```
[ローカルの Docker コンテナ] --GetObject/PutObject--> [実際の S3]
```

したがって次が要る。

- **Docker が起動していること**（`docker info` が通る）
- **AWS 認証情報**（`aws sts get-caller-identity` が通る）
- **実在する S3 バケットと、その中に置いた原本**

バケットがまだ無いなら、先に [deploy.md](deploy.md) でデプロイするのが早い。
S3 を触らずに画像処理だけ見たい場合は [test-local.md](test-local.md) で足りる。

---

## 1. 準備

```bash
docker info >/dev/null && echo OK          # Docker
aws sts get-caller-identity                 # 認証情報
make build                                  # .aws-sam/build を作る
```

`make build` は済ませておく。`sam local invoke` はビルド済みの成果物を使う。

## 2. 環境変数とイベント

`events/` に用意してある。

| ファイル | 内容 |
|---|---|
| `events/env.json` | 関数に渡す環境変数。**`INPUT_BUCKET` を自分のバケット名に書き換える** |
| `events/request.json` | リクエスト起動のペイロード |
| `events/s3-notification.json` | S3 イベント通知のペイロード |

`env.json` の `INPUT_BUCKET` / `OUTPUT_BUCKET` と、イベント側のバケット名・キーは
揃っている必要がある。揃っていないと「バケットが違う」「レイアウトに合わない」で弾かれる。

```bash
BUCKET=image-mask-dev-$(aws sts get-caller-identity --query Account --output text)
sed -i '' "s/image-mask-dev-000000000000/$BUCKET/g" events/env.json events/s3-notification.json
```

## 3. 原本を置く

```bash
make sample
aws s3 cp testdata/idcard.jpg \
  "s3://$BUCKET/t-001/no-masked/2026-09-14/loc-12/e-98765"
```

`KEY_PREFIX` を設定している場合は、キーの先頭にその階層を足す。

## 4. リクエスト起動を試す

```bash
sam local invoke MaskFunction \
  --env-vars events/env.json \
  -e events/request.json
```

期待する出力（ログのあとに応答の JSON）:

```json
{"sourceKey":"t-001/no-masked/2026-09-14/loc-12/e-98765",
 "outputKey":"t-001/masked/2026-09-14/loc-12/e-98765",
 "skipped":false,"radiusPx":36,"strengthScore":1.15}
```

2 回目は `"skipped":true` になる（冪等）。結果を取り出して目で見る。

```bash
aws s3 cp "s3://$BUCKET/t-001/masked/2026-09-14/loc-12/e-98765" tmp/from-sam.jpg
```

## 5. S3 イベント通知の形を試す

イベント通知そのものは配線していなくても、**ペイロードの解釈だけ**は確認できる。

```bash
sam local invoke MaskFunction \
  --env-vars events/env.json \
  -e events/s3-notification.json
```

S3 イベント通知経由では応答が `null` になる（戻り値を返さない側の経路）。処理されたかどうかは
ログと、出力オブジェクトの有無で確認する。

キーの `infix` を `masked` に書き換えて実行すると、`skip: not an original` が出て
何もしない（再帰ループ防止の確認）。

## 6. HTTP で繰り返し叩きたい場合

```bash
sam local start-lambda --env-vars events/env.json
```

別のターミナルから:

```bash
aws lambda invoke --function-name MaskFunction \
  --endpoint-url http://127.0.0.1:3001 --no-verify-ssl \
  --payload file://events/request.json \
  --cli-binary-format raw-in-base64-out tmp/out.json && cat tmp/out.json
```

---

## つまずきやすい点

| 症状 | 原因と対処 |
|---|---|
| `Error: Running AWS SAM projects locally requires Docker` | Docker が起動していない |
| `NoCredentialProviders` / 403 | コンテナに認証情報が渡っていない。`aws configure` 済みか、`--profile` を付ける |
| `bucket ... is not the configured input bucket` | `events/env.json` の `INPUT_BUCKET` とイベントのバケット名が違う |
| `key ... has N segments, want 5` | キーの形が `[<prefix>/]<tid>/<infix>/<date>/<lid>/<eid>` と一致していない。`KEY_PREFIX` の設定と突き合わせる |
| `object not found` | S3 に原本を置いていない（→ 3.） |
| 応答が `null` | S3 イベント通知のペイロードを渡した場合は正常。リクエスト起動なら JSON が返る |
| 初回が遅い | ランタイムのコンテナイメージを取得している。2 回目以降は速い |

---

## 検証状況

**この手順は未検証。** 作成環境では Docker が起動しておらず、AWS 認証情報も未設定のため、
`sam local invoke` を実行できていない。

イベントファイル（`events/*.json`）については、**実際のハンドラと同じ型で読み込み、
キーがレイアウトと一致することをプログラムで確認済み**。2 つのイベントが同じオブジェクトを
指すことも確認してある。

---

## 次の段階

- AWS へ反映する → [deploy.md](deploy.md)
