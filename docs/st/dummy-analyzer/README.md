# ダミーの画像解析サーバー（検証環境用）

検証環境で、チケット QR API の解析クライアントの動き（時間切れとやり直し、REJECT・RETRY、解析サーバーの失敗）を確かめるための、ダミーの画像解析サーバー。AWS SAM で、Python の Lambda と、認証なしの関数 URL として作る。手順の全体は [../PROD_VERIFICATION.md](../PROD_VERIFICATION.md) 3.3・5章。

- [../analyzer-stub/](../analyzer-stub/)（解析サーバーのスタブ。常に `PASS`、`x-api-key` を確かめる）とは別のもの。こちらは、返す判定・待つ時間・失敗を選べる
- 画像は読まない（受け取った大きさだけをログに出す）。**本番では使わない**（本番の `AnalyzerUrl` を向けない）
- 関数 URL は誰でも呼べる（同時実行数を 5 に絞ってある）。使い終わったら消す（4章）

## 1. ファイル

| ファイル | 内容 |
|---|---|
| `template.yaml` | SAM の定義（関数、関数 URL、ロググループ）。振る舞いの既定はパラメータで決める |
| `src/app.py` | 関数の本体（標準のライブラリだけ） |
| `tests/test_app.py` | 単体テスト（`python3 -m unittest discover -s dummy-analyzer/tests`） |

## 2. 振る舞い

関数の環境変数（スタックのパラメータで決める既定）と、URL のクエリ（その要求だけ上書き）で決める。

| 設定 | パラメータ（環境変数） | クエリ | 値 | 既定 |
|---|---|---|---|---|
| 返す判定 | `Result`（`DUMMY_RESULT`） | `result` | `PASS` / `REJECT` / `RETRY` | `PASS` |
| 応答の前に待つ秒数 | `Delay`（`DUMMY_DELAY`） | `delay` | 0〜50（小数可） | 0 |
| 返すステータス | `Status`（`DUMMY_STATUS`） | `status` | 200〜599。200 以外なら本文なし | 200 |
| 本文の形 | `Body`（`DUMMY_BODY`） | `body` | `json` / `garbage`（JSON でない本文） | `json` |

- 返す本文は、本物と同じ形の `{"confidence","detected","reason","result","status"}`（API が見るのは `result` だけ）
- 設定の値が正しくなければ 400（本文に理由）
- ログ（`/aws/lambda/<名前>`）に、呼ばれるたびに `"msg":"dummy analyzer called"` と、そのときの設定・受け取った大きさ・`x-api-key` が付いていたか（値は出さない）を出す。やり直しの回数は、この行の数で数える

チケット QR API から見た結果（API の解析クライアントの既定: 1 回 5 秒、やり直し 1 回）:

| ダミーの設定 | API の応答 |
|---|---|
| `result=PASS`（`delay` が 5 秒未満） | 201 |
| `result=REJECT` / `result=RETRY` | 422 `IMAGE_REJECTED` / `IMAGE_RETRY` |
| `status=500`（5xx） | 502 `ANALYSIS_UPSTREAM_ERROR`（1 回やり直す） |
| `status=400`（4xx） | 502 `ANALYSIS_UPSTREAM_ERROR`（やり直さない） |
| `body=garbage` | 502 `ANALYSIS_UPSTREAM_ERROR` |
| `delay=7`（5 秒以上） | 約 10 秒で 504 `ANALYSIS_TIMEOUT`（ダミーは 2 回呼ばれる） |

手元で、API（Go）からこの関数の本体を呼んで、上の表のとおりになることを確かめた（2026-10-16。関数 URL の代わりに、HTTP の要求を同じ形のイベントにして渡す小さなサーバーを使った）。AWS 上では未確認。

## 3. デプロイ

前提: SAM CLI（例: `uvx --from aws-sam-cli sam …`）、AWS の認証情報。検証環境のアカウント・リージョンで行う。

```sh
export DUMMY_STACK=ticketqr-stg-dummy-analyzer

sam build --template-file dummy-analyzer/template.yaml --build-dir dummy-analyzer/.aws-sam/build
sam deploy --template-file dummy-analyzer/.aws-sam/build/template.yaml \
  --stack-name $DUMMY_STACK --resolve-s3 --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset

export DUMMY_URL=$(aws cloudformation describe-stacks --stack-name $DUMMY_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='AnalyzeUrl'].OutputValue" --output text)

# ダミーだけで動きを確かめる（3 秒待って PASS が返る）
curl -s -w ' %{http_code} %{time_total}s\n' -X POST --data-binary @testdata/images/photo.jpg "${DUMMY_URL}?delay=3"
```

- 関数とロググループの名前は、スタック名（`NamePrefix` を指定したらその値）
- `--resolve-s3` は、SAM が用意する S3 のバケットにコードを置く。成果物バケットを使うなら `--s3-bucket $ARTIFACT_BUCKET --s3-prefix dummy-analyzer` にする

### 3.1 チケット QR API をダミーにつなぐ

検証環境の API のスタック（`api.yaml` または infra/sam）を、`AnalyzerMode=http`、`AnalyzerUrl=$DUMMY_URL` にする（ほかのパラメータは前の値のまま。手順は ../PROD_VERIFICATION.md 3.3）。API のスタックに `AnalyzerApiKeyParameterName` があっても、ダミーは `x-api-key` を見ないので、そのままでよい。

### 3.2 振る舞いを変える

つないだ後は、**ダミーの側だけを変える**（API のスタックは更新しない）。

```sh
# 既定を変える（スタックのパラメータ。数十秒〜）
sam deploy --template-file dummy-analyzer/.aws-sam/build/template.yaml --stack-name $DUMMY_STACK \
  --resolve-s3 --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides Result=PASS Delay=7 Status=200 Body=json
```

- `--parameter-overrides` には、4 つ（`Result`・`Delay`・`Status`・`Body`）をまとめて書く（書かなかったものは、前の値のまま）
- 1 回だけ違う振る舞いにしたいときは、API のスタックの `AnalyzerUrl` にクエリを付ける方法もある（例: `${DUMMY_URL}?result=REJECT`）。ただし API のスタックの更新が要るので、既定を変えるほうが早い

## 4. 削除

先に、API のスタックの `AnalyzerUrl` を元の解析サーバーに戻す。

```sh
sam delete --stack-name $DUMMY_STACK --no-prompts
```

ロググループもスタックと一緒に消える。
