# 本番環境向け 検証・確認手順

本物の AWS 環境（CloudFront → API Gateway → Lambda、本物の解析サーバー）で、次の 5 項目を確かめる手順。手元での手順は [TEST_PROCEDURES.md](TEST_PROCEDURES.md)、結果は [TEST_RESULT.md](TEST_RESULT.md) に書く。

| TEST_RESULT.md | 項目 | 本番で確かめられること | 検証環境が要ること | 本書 |
|---|---|---|---|---|
| 3.3-3 | 画像の形式の判別、4MiB の上限 | すべて | - | 2章 |
| 3.3-2 | エラー 413 / 415 / 422 / 502 / 504 の JSON | 413、415、422（REJECT）、Lambda に届かない大きさの応答 | REJECT・RETRY・502・504 を選んで起こす（ダミーの解析サーバー。dummy-analyzer/） | 3章 |
| 3.2-5 | 30 秒のタイムアウト、通信の失敗 | すべて（実機を機内モードにする） | - | 4章 |
| 3.3-9 | 解析サーバーのタイムアウト（1 回 5 秒、やり直し 1 回、約 10 秒で 504） | - | すべて（応答の遅いダミーの解析サーバーにつなぐ） | 5章 |
| 3.3-8 | `Cache-Control: no-store` | すべて | - | 6章 |

- **本番環境**: 利用者が使う環境。設定（スタックのパラメータ、Lambda の設定）は変えない。発行は最小の回数にする
- **検証環境**: 本番と同じテンプレート・同じ構成（統合、VPC、NAT、本物の解析サーバーか同じ形のスタブ）で作った別の環境。設定を一時的に変えてよい

## 0. 本番で行うときの決まり

| 決まり | 理由 |
|---|---|
| 発行（判定が通る画像の送信）は、手順に書いた回数だけにする | 1 回ごとに解析サーバーに画像が送られ（費用・負荷）、発行の上限（1 時間 10,000 件・1 日 100,000 件。infra/RATE_LIMITING.md 7章）にも数えられる |
| 送る証明書の画像は、試験用に用意したものだけを使う | 解析サーバーとログに画像の情報が残る。本物の利用者の画像や、個人の情報が写ったものは使わない |
| スタックのパラメータ、Lambda の環境変数、解析サーバーの接続先は変えない | 502・504 を起こすには接続を壊す必要があり、その間は利用者も発行できなくなる。それらは検証環境で行う（3.3） |
| 実施する日時を、運用の担当者と解析サーバーの担当者に伝える | 解析サーバーの側で、試験の送信と分かるようにする |
| 応答ごとに、`apigw-requestid` と時刻を記録する | CloudWatch のログ（API Gateway・Lambda）と照らし合わせるため（1.4） |
| WAF を付けている環境では、試験の送信がブロックされないかを先に確かめる | curl の送信がルールで止められると、API の応答を確かめられない（403 の HTML になる） |

## 1. 準備

### 1.1 変数

```sh
export AWS_REGION=ap-northeast-1
export IMPL=go
export WEB_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-web-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='WebUrl'].OutputValue" --output text)
export BASE=$WEB_URL                                   # 統合の構成: CloudFront の /v1/* に送る
export TICKETS_LOG=/aws/lambda/ticketqr-$IMPL-tickets
export GETQR_LOG=/aws/lambda/ticketqr-$IMPL-get-qr
export ACCESS_LOG=/aws/apigateway/ticketqr-$IMPL
export WORK=$(mktemp -d)
```

- SAM で作った環境では、関数とロググループの名前の先頭が `NamePrefix`（既定はスタック名）になる（infra/sam/README.md 3章）
- 画像の上限を下げた環境（`MaxImageBytes`）か確かめる。下げていれば、2章の境界のファイルをその値に合わせる

  ```sh
  aws lambda get-function-configuration --function-name ticketqr-$IMPL-tickets \
    --query 'Environment.Variables.MAX_IMAGE_BYTES' --output text     # None なら 4MiB（4194304）
  curl -s $WEB_URL/config.json                                          # 画面の maxImageBytes（同じ値のはず）
  ```

### 1.2 送る画像

| ファイル | 作り方 | 使う章 |
|---|---|---|
| `cert.jpg` | 判定が通る証明書の写真（試験用）。4MB 以下の JPEG | 2・3・5 |
| `cert.png`・`cert.heic`・`cert.avif` | `cert.jpg` から sips で作る（下） | 2 |
| `cert.webp` | `cert.jpg` から cwebp で作る（`brew install webp`） | 2 |
| `cert.heif` | Android の端末で撮った HEIF の写真（試験用の証明書）。手元の道具では作りにくい | 2（用意できなければ省き、単体テストに任せる） |
| `other.jpg` | 証明書でない写真（風景など） | 3（REJECT） |
| `blurry.jpg` | 暗い・ぼやけた証明書の写真 | 3（RETRY。解析サーバーが RETRY を返すとは限らない） |
| `testdata/images/not-image.txt` | リポジトリにある | 2・3 |
| `max.bin`・`over.bin`・`b.bin`・`c.bin` | ゼロで埋めたファイル（下） | 2・3 |

```sh
sips -s format png  cert.jpg --out $WORK/cert.png
sips -s format heic cert.jpg --out $WORK/cert.heic
sips -s format avif cert.jpg --out $WORK/cert.avif
cwebp -q 90 cert.jpg -o $WORK/cert.webp
cp cert.jpg other.jpg blurry.jpg $WORK/                # 用意した写真（docs/st に置いた場合）
cp testdata/images/not-image.txt $WORK/
cp testdata/images/not-image.txt $WORK/fake.jpg       # 拡張子だけ JPEG にしたもの

head -c 4194304  /dev/zero > $WORK/max.bin    # ちょうど 4MiB: 大きさは通り、形式で 415
head -c 4194305  /dev/zero > $WORK/over.bin   # 4MiB + 1 バイト: 413
head -c 5242880  /dev/zero > $WORK/b.bin      # 5MB: base64 で 6MB を超え、Lambda に届かない
head -c 11534336 /dev/zero > $WORK/c.bin      # 11MB: API Gateway の 10MB を超える
```

### 1.3 送るコマンド

発行の API（`POST /v1/tickets`）には、次の形の curl で 1 件ずつ送る。`image=@…` のファイルだけを変える。`-i` で応答のヘッダーと本文を表示し、`tee -a` で記録用のファイル（`$WORK/record.txt`）にも残す。

```sh
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.jpg" "$BASE/v1/tickets" | tee -a $WORK/record.txt
```

表示のうち、主に見るもの:

| 見るもの | 意味 |
|---|---|
| 最後の行の `status=` | ステータス |
| `content-type` | API の JSON なら `application/json; charset=utf-8` |
| `cache-control`・`x-content-type-options` | 6章 |
| `apigw-requestid` | あれば API Gateway まで届いている。なければ CloudFront（または WAF）で止まっている。ログと照らし合わせるのに使う（1.4） |
| `x-cache`・`x-amz-cf-id` | CloudFront を通ったこと。CloudFront に問い合わせるときの ID |
| 本文 | 201 は `{ ticketCode, issuedAt, sig, qrUrl }`、エラーは `{"error":{"code":…}}` |

- 統合の構成なので、`Origin` のヘッダーは要らない（同じオリジン）

### 1.4 ログを見る

```sh
# 発行の関数: 要求ごとの完了のログ（status・endpoint・requestId・client）
aws logs tail $TICKETS_LOG --since 15m --filter-pattern '"request completed"' --format short
# 発行の関数: 解析サーバーの応答（届いた本文がそのまま出る。413・415 では出ない＝解析サーバーを呼んでいない）
aws logs tail $TICKETS_LOG --since 15m --filter-pattern '"analyzer response"' --format short
# API Gateway のアクセスログ: status と integrationError（Lambda を呼べなかった理由）
aws logs tail $ACCESS_LOG --since 15m --format short
```

- 応答の `apigw-requestid` は、アクセスログの `requestId` と、Lambda のログの `requestId` に同じ値で出る。これで 1 件ずつ照らし合わせる
- まとめて見るときは、CloudWatch Logs Insights で `$TICKETS_LOG` を選び、次を流す

  ```
  fields @timestamp, requestId, endpoint, status, durationMs
  | filter msg = "request completed"
  | sort @timestamp desc
  ```

## 2. 画像の形式の判別、4MiB の上限（3.3-3）

本番で行える。発行は 5〜6 回（形式ごとに 1 回）。

```sh
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.jpg" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.png" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.heic" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.avif" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.webp" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.heif" "$BASE/v1/tickets" | tee -a $WORK/record.txt   # 用意できたときだけ
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/not-image.txt" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/fake.jpg" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/max.bin" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/over.bin" "$BASE/v1/tickets" | tee -a $WORK/record.txt
```

期待結果:

| 送ったもの | ステータス | 本文の `error.code` | 解析サーバーへの送信（1.4 の `analyzer response`） |
|---|---|---|---|
| `cert.jpg`・`.png`・`.heic`・`.avif`・`.webp`（・`.heif`） | 201 | -（`ticketCode`・`issuedAt`・`sig`・`qrUrl`） | あり（`result` が `PASS`） |
| `not-image.txt` | 415 | `UNSUPPORTED_MEDIA_TYPE` | なし |
| `fake.jpg`（中身はテキスト） | 415 | `UNSUPPORTED_MEDIA_TYPE` | なし（拡張子ではなく中身で判別する） |
| `max.bin`（ちょうど 4MiB） | 415 | `UNSUPPORTED_MEDIA_TYPE` | なし（大きさは通り、形式で断られる） |
| `over.bin`（4MiB + 1 バイト） | 413 | `PAYLOAD_TOO_LARGE` | なし |

結果の見方:

- 形式の判別（API）が正しいことは、**415 にならず、解析サーバーまで届いたこと**で分かる。201 にならず 422 や 502 になった形式は、API は受け付けたが、解析サーバーがその形式を扱えなかった（または判定が変わった）ということ。`analyzer response` の本文を備考に写し、解析サーバーの担当者に確かめる（どの形式を送ってよいかは、画面の縮小が JPEG にするかどうかにも関わる）
- 201 の `qrUrl` が `$WEB_URL/v1/...` で始まること（統合の構成の公開 URL）も、あわせて見る

## 3. エラー 413 / 415 / 422 / 502 / 504 の JSON（3.3-2）

### 3.1 本番で行えるもの

```sh
# 413・415 は 2章の結果を使う（同じ形を確かめる）
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/other.jpg" "$BASE/v1/tickets" | tee -a $WORK/record.txt   # 証明書でない写真 → 422 IMAGE_REJECTED の見込み
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/blurry.jpg" "$BASE/v1/tickets" | tee -a $WORK/record.txt   # 暗い・ぼやけた写真 → 422 IMAGE_RETRY になれば確かめられる
```

期待結果（どれも共通）:

- `content-type: application/json; charset=utf-8`、本文が `{"error":{"code":"…","message":"…"}}`
- CloudFront が本文を置き換えていない（CloudFront の HTML のエラーページではなく、API の JSON のまま。`x-cache` が `Error from cloudfront` でも、本文は JSON）
- `cache-control: no-store`

| 送ったもの | 期待 | 確かめられないとき |
|---|---|---|
| `over.bin` | 413 `PAYLOAD_TOO_LARGE` | - |
| `not-image.txt` | 415 `UNSUPPORTED_MEDIA_TYPE` | - |
| `other.jpg` | 422 `IMAGE_REJECTED` | 201 になったら、解析サーバーが証明書と判定した。別の写真で試す |
| `blurry.jpg` | 422 `IMAGE_RETRY` | 解析サーバーが RETRY を返す条件が分からなければ、検証環境（3.3）で確かめる |

- 判定の結果は、1.4 の `analyzer response` で、解析サーバーが返した `result` と照らし合わせる（API の 422 のコードと一致していること）

### 3.2 Lambda に届かない大きさ（本番で行える。記録だけ）

画面は送る前に止めるので、普段は起きない。API Gateway・CloudFront が何を返すかを記録する（web/DEPLOY.md 12章。期待値はまだ決めていない）。

```sh
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/b.bin" "$BASE/v1/tickets" | tee -a $WORK/record.txt
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/c.bin" "$BASE/v1/tickets" | tee -a $WORK/record.txt
aws logs tail $ACCESS_LOG --since 10m --format short    # status と integrationError
aws logs tail $TICKETS_LOG --since 10m --filter-pattern '"request completed"' --format short   # 出なければ Lambda は呼ばれていない
```

記録すること: ステータス、`content-type`、本文の先頭、`apigw-requestid` の有無、アクセスログの `integrationError`。結果は web/DEPLOY.md 12.3 の表にも書く。画面で出る文言（JSON でない応答は「発行できませんでした…」の扱い）も、あわせて決める。

### 3.3 検証環境で行うもの（REJECT・RETRY・502・504）

解析サーバーの判定や失敗を選んで起こすため、**本番では行わない**。検証環境の API を、ダミーの解析サーバー（[dummy-analyzer/](dummy-analyzer/README.md)。SAM でデプロイする Python の Lambda）につなぎ、ダミーの設定を変えながら送る。

**1. ダミーをデプロイして、API をつなぐ（最初に 1 回）**

```sh
# ダミーをデプロイ（dummy-analyzer/README.md 3章）
export DUMMY_STACK=ticketqr-stg-dummy-analyzer
sam build --template-file dummy-analyzer/template.yaml --build-dir dummy-analyzer/.aws-sam/build
sam deploy --template-file dummy-analyzer/.aws-sam/build/template.yaml --stack-name $DUMMY_STACK --resolve-s3 --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides Result=PASS Delay=0 Status=200 Body=json
export DUMMY_URL=$(aws cloudformation describe-stacks --stack-name $DUMMY_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='AnalyzeUrl'].OutputValue" --output text)

# 検証環境の API のスタック。元のパラメータを控えてから、AnalyzerMode と AnalyzerUrl だけを変える（ほかは前の値のまま）
export STACK=ticketqr-stg-$IMPL
aws cloudformation describe-stacks --stack-name $STACK --query 'Stacks[0].Parameters' --output table   # 元の値を控える
PARAMS=$(aws cloudformation describe-stacks --stack-name $STACK --query 'Stacks[0].Parameters[].ParameterKey' --output text \
  | tr '\t' '\n' | grep -vE '^(AnalyzerMode|AnalyzerUrl)$' | sed 's/.*/ParameterKey=&,UsePreviousValue=true/')
aws cloudformation update-stack --stack-name $STACK --use-previous-template --capabilities CAPABILITY_IAM \
  --parameters $PARAMS ParameterKey=AnalyzerMode,ParameterValue=http ParameterKey=AnalyzerUrl,ParameterValue=$DUMMY_URL
aws cloudformation wait stack-update-complete --stack-name $STACK
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.jpg" "$BASE/v1/tickets" | tee -a $WORK/record.txt   # → 201（ダミーの既定は PASS）
```

**2. ダミーの設定を変えて送る（API のスタックは変えない）**

| ダミーの設定（`--parameter-overrides`） | 期待 | 時間の目安 |
|---|---|---|
| `Result=REJECT Delay=0 Status=200 Body=json` | 422 `IMAGE_REJECTED` | すぐ |
| `Result=RETRY Delay=0 Status=200 Body=json` | 422 `IMAGE_RETRY` | すぐ |
| `Result=PASS Delay=0 Status=500 Body=json` | 502 `ANALYSIS_UPSTREAM_ERROR`（5xx は 1 回やり直す。ダミーは 2 回呼ばれる） | すぐ |
| `Result=PASS Delay=0 Status=200 Body=garbage` | 502 `ANALYSIS_UPSTREAM_ERROR`（JSON でない応答） | すぐ |
| `Result=PASS Delay=7 Status=200 Body=json` | 504 `ANALYSIS_TIMEOUT` | 約 10 秒（5章） |

```sh
# 例: REJECT
sam deploy --template-file dummy-analyzer/.aws-sam/build/template.yaml --stack-name $DUMMY_STACK --resolve-s3 --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides Result=REJECT Delay=0 Status=200 Body=json
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.jpg" "$BASE/v1/tickets" | tee -a $WORK/record.txt   # → 422 IMAGE_REJECTED
```

**3. 元に戻す（最後に 1 回）**: API のスタックの `AnalyzerMode`・`AnalyzerUrl` を、控えた元の値に戻し（1. の `update-stack` と同じ形）、201 に戻ることを確かめてから、ダミーを消す（`sam delete --stack-name $DUMMY_STACK --no-prompts`）。

- どの場合も、本文が `{"error":{"code":…}}` の JSON で、CloudFront が置き換えていないことを見る（3.1 と同じ）
- 1.4 のログで照らし合わせる: 発行の関数の `analyzer response`（ダミーが返したステータスと本文。時間切れでは出ない）と `request completed` の `status`。ダミーのログ（`/aws/lambda/$DUMMY_STACK`）の `"dummy analyzer called"` の行の数で、やり直しの回数が分かる
- 解析サーバーそのものに届かない場合（接続を断られる・どこにも届かない）は、ダミーでは作れない。必要なら、`AnalyzerUrl` を `https://127.0.0.1:9/v1/analyze`（すぐに断られる → 502）や `https://192.0.2.1/v1/analyze`（応答がない → 約 10 秒で 504）にして確かめる

## 4. 30 秒のタイムアウト、通信の失敗（3.2-5）

本番で行える。30 秒のタイムアウトは、通信を待たせる仕組みを作らず、**実機で通信を切って確かめる**（通信の失敗と同じ扱いの文言になることを見る）。

1. 実機（iPhone・Android）で `$WEB_URL` を開き、`cert.jpg` を選んで、「発行する」が押せる状態にする
2. 機内モードにする（Wi-Fi も切る）
3. 「発行する」を押す

期待結果: ボタンの下のエラーの枠に文言が出て、「発行する」がもう一度押せる。

4. 機内モードを切って、もう一度押す → 発行でき、チケット画面に移る（発行 1 回）

- 文言は TEST_RESULT.md の 3.2-5 の期待結果と照らし合わせる（TEST_PROCEDURES.md 冒頭の注意のとおり、今の実装の文言とは違う）
- 手元で 30 秒のタイムアウトそのものを起こす手順は TEST_PROCEDURES.md 2.3

## 5. 解析サーバーのタイムアウト（3.3-9。検証環境）

API は解析サーバーの応答を 1 回 5 秒（`ANALYZER_TIMEOUT_MS`。既定 5000）待ち、時間切れなら 1 回だけやり直す。2 回とも時間切れなら、約 10 秒で 504 `ANALYSIS_TIMEOUT` を返す。これを、3.3 のダミーの解析サーバーの待ち時間（`Delay`）を変えて確かめる。3.3 の 1.（ダミーをデプロイして API をつなぐ）を済ませておく。

| ダミーの `Delay` | 期待 | 時間（`time=`） | ダミーが呼ばれた回数 |
|---|---|---|---|
| `3` | 201（5 秒以内に応答があれば発行される） | 約 3 秒 | 1 回 |
| `7` | 504 `ANALYSIS_TIMEOUT` | 約 10 秒 | 2 回（やり直しを含む） |
| `30` | 504 `ANALYSIS_TIMEOUT` | 約 10 秒（30 秒待たない） | 2 回 |

```sh
# 例: Delay=7
sam deploy --template-file dummy-analyzer/.aws-sam/build/template.yaml --stack-name $DUMMY_STACK --resolve-s3 --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides Result=PASS Delay=7 Status=200 Body=json
curl -s -i -w '\nstatus=%{http_code} time=%{time_total}s\n' -H 'Accept: application/json' -F "image=@$WORK/cert.jpg" "$BASE/v1/tickets" | tee -a $WORK/record.txt   # → 504、time=約 10 秒

# ダミーが呼ばれた回数（"dummy analyzer called" の行の数）
aws logs tail /aws/lambda/$DUMMY_STACK --since 5m --filter-pattern '"dummy analyzer called"' --format short
# 発行の関数: status 504、durationMs が約 10000
aws logs tail $TICKETS_LOG --since 5m --filter-pattern '"request completed"' --format short
```

- 時間は、解析サーバーを待つ時間（5 秒 × 2 回）に、ダミーの起動などの時間が少し加わる。ダミーを初めて呼ぶときは起動の分だけ遅くなるので、先に `Delay=0` で一度送っておく
- `ANALYZER_TIMEOUT_MS` を変えた環境では、5 秒をその値に読み替える
- 画面からも確かめる場合は、`Delay=7` の状態で発行し、約 10 秒後にエラーの枠に「混み合っています」の扱いの文言が出ることを見る
- 終わったら、3.3 の 3.（元に戻す）を行う

## 6. `Cache-Control: no-store`（3.3-8）

本番で行える。発行は 1 回（2章の `cert.jpg` の結果を使えば 0 回）。

```sh
hdr() { grep -iE '^(HTTP/|cache-control:|x-content-type-options:|content-type:|x-cache:|age:)'; }

# 1. 発行の 201
curl -s -D - -o $WORK/ticket.json -H 'Accept: application/json' -F image=@$WORK/cert.jpg $BASE/v1/tickets | hdr
# 2. 発行のエラー（415・413）
curl -s -D - -o /dev/null -H 'Accept: application/json' -F image=@$WORK/not-image.txt $BASE/v1/tickets | hdr
curl -s -D - -o /dev/null -H 'Accept: application/json' -F image=@$WORK/over.bin $BASE/v1/tickets | hdr
# 3. QR 画像の 200 を 2 回（CloudFront にも保存されないこと）
QR=$(python3 -c 'import json;print(json.load(open("'$WORK'/ticket.json"))["qrUrl"])')
curl -s -D - -o /dev/null "$QR" | hdr
curl -s -D - -o /dev/null "$QR" | hdr
# 4. QR 画像の 403（sig を壊す）
curl -s -D - -o /dev/null "${QR%sig=*}sig=xxxxxxxxxxxxxxxxxxxxxx" | hdr
```

期待結果:

| 応答 | 期待 |
|---|---|
| 1〜4 のすべて | `cache-control: no-store`、`x-content-type-options: nosniff` |
| 3 の 2 回目 | `x-cache: Miss from cloudfront`（`Hit` にならない）。`age` のヘッダーがない（CloudFront が保存した応答ではない） |

ブラウザでも確かめる（PC の Chrome、本番の画面）:

1. デベロッパーツールのネットワークのタブを開き、「キャッシュを無効にする」は**外す**
2. 発行して、チケット画面を出す
3. チケット画面を再読み込みする
4. `…/qr?sig=…` の要求を選び、応答のヘッダーに `cache-control: no-store` があること、「サイズ」の欄が `(memory cache)`・`(disk cache)` ではなく、通信した大きさであることを見る

## 7. 記録

- TEST_RESULT.md の該当の行に、実施日・結果・実施者を書き、備考に「本番」か「検証環境」かと、`$WORK/record.txt` の要点（ステータス、`apigw-requestid`）を書く
- 3.2（Lambda に届かない大きさ）の結果は、web/DEPLOY.md 12.3 の表にも書く
- 作業が終わったら、`$WORK` を消す（証明書の画像が入っている）
