# 未実施のテストの確認手順

[TEST_RESULT.md](TEST_RESULT.md) で、まだ実施していない項目（実施日が空の 11 項目）を、どう確かめるかをまとめる。確かめたものは「状態」を対応済みにする（2026-10-16 時点で 7 項目）。項目の番号は TEST_RESULT.md のもの（[TEST_SCOPE.md](TEST_SCOPE.md) では 2.x）。結果は TEST_RESULT.md の実施日・結果・実施者・備考に書く。

| TEST_RESULT.md | 項目 | 環境 | 本書 | 状態 |
|---|---|---|---|---|
| 3.1-3 | 4MB 超の縮小 | 実機（手元 か AWS） | 2.1 | ☑ 対応済み（確認済み） |
| 3.2-1 | 画像の大きさ超過のエラー文言 | 実機（手元 か AWS） | 2.2 | ☑ 対応済み（確認済み） |
| 3.2-5 | 30 秒のタイムアウト、通信の失敗 | 実機（手元） | 2.3 | 未実施。本番環境向けの手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md) |
| 3.3-2 | エラー 413 / 415 / 422 / 502 / 504 の JSON | curl（手元）と AWS | 2.4 | 未実施。本番環境向けの手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md) |
| 3.3-3 | 画像の形式の判別、4MiB の上限 | curl（手元 か AWS） | 2.5 | 未実施。本番環境向けの手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md) |
| 3.3-7 | ブラウザと OS の情報のログ | 実機と AWS（CloudWatch） | 2.6 | ☑ 対応済み（確認済み） |
| 3.3-8 | `Cache-Control: no-store` | curl か デベロッパーツール | 2.7 | 未実施。本番環境向けの手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md) |
| 3.3-9 | 解析サーバーのタイムアウト（約 10 秒で 504） | AWS（検証環境。ダミーの解析サーバー） | - | 未実施。手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md) 5章 |
| 3.4-2 | 再読み込み・後で開く（再発行しない） | 実機と AWS（CloudWatch） | 2.8 | ☑ 対応済み（確認済み） |
| 3.4-4 | QR 画像 API（200 PNG、sig 違いは 403） | curl か デベロッパーツール | 2.9 | ☑ 対応済み（確認済み） |
| 3.5-2 | ルートの振り分け（発行・QR） | curl・デベロッパーツール と AWS | 2.10 | ☑ 対応済み（確認済み） |
| 3.5-7 | CSP | AWS（CloudFront） | 2.11 | ☑ 対応済み（確認済み） |

> **注意（3.2 の期待結果の文言）**: TEST_RESULT.md の 3.2-3〜3.2-5 の期待結果（「判定ができませんでした。再度お試しください」「画像の送付に失敗しました。少し待ってから再度お試しください」）は、今の実装の文言（[CHANGES.md](CHANGES.md) 1-3）と違う。文言を変えるか、期待結果を直すかを決めてから確かめる。本書の手順は、どちらの文言でも同じ。

## 1. 共通の準備

### 1.1 手元の環境

```sh
cd docs/st
# API（解析サーバーは呼ばず、常に PASS。ポート 8080）
make -C go run
# 画面（別の端末で。/v1 は 8080 の API に転送される。http://127.0.0.1:5173/）
npm --prefix web run dev
```

- **実機（スマートフォン）から手元の画面を開く**: 同じ Wi-Fi につなぎ、`npm --prefix web run dev -- --host 0.0.0.0` で起動して、`http://<Mac の IP>:5173/` を開く（Mac の IP は `ipconfig getifaddr en0`。macOS のファイアウォールの確認が出たら許可する）
- **手元では確かめられないこと**: CloudFront が付けるヘッダー（CSP など）、HTTPS でしか届かない Client Hints、API Gateway の上限。これらは AWS で確かめる
- チケット画面の QR は、画面と同じオリジンの `/v1/…/qr` から読む（`config.json` の `apiBaseUrl` が `""`）ので、実機から開いても 5173 の転送で表示される

### 1.2 解析サーバーの代わり（エラーを起こす）

今のスタブは常に `PASS` を返す（判定を切り替える機能は未実装。analyzer-stub/DESIGN.md 4章）。REJECT・RETRY・解析の失敗・時間切れは、手元で次の小さなサーバーを解析サーバーの代わりにして起こす。

```python
# fake_analyzer.py（作業用のディレクトリに置く）
# 使い方: python3 fake_analyzer.py <PASS|REJECT|RETRY|error|garbage|hang> [ポート]
#   error = 500、garbage = JSON でない応答、hang = 応答しない（時間切れ）
# 受け取った画像は received.bin に保存する（縮めた写真の向き・大きさの確認用）
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 9000

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open("received.bin", "wb") as f:
            f.write(body)
        if mode == "hang":
            time.sleep(3600)
        if mode == "error":
            self.send_response(500)
            self.end_headers()
            return
        out = b"not json" if mode == "garbage" else json.dumps({"result": mode}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out)

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
```

```sh
# 解析サーバーの代わりを起動（判定を変えるときは止めて起動し直す）
python3 fake_analyzer.py REJECT 9000

# API を、解析サーバーの代わりにつないで起動（8080 の API を止めてから。画面からも使える）
cd docs/st/go
ANALYZER_MODE=http ANALYZER_URL=http://127.0.0.1:9000/v1/analyze ANALYZER_TIMEOUT_MS=1000 make run
```

- `ANALYZER_TIMEOUT_MS` は、解析サーバーを待つ時間（1 回分。既定 5000）。時間切れの確認を早く終えるために短くしている
- 画面を使わず curl だけで確かめるなら、8080 の API はそのままにして、別のポートで起動してもよい（`go run ./cmd/ticketqr -addr :8081`）

### 1.3 AWS の環境

```sh
export IMPL=go
export WEB_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-web-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='WebUrl'].OutputValue" --output text)
export API_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-$IMPL \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
# 統合の構成では、curl の送り先は $WEB_URL（CloudFront の /v1/*）。直接の構成では $API_URL
export BASE=$WEB_URL
```

- ログ: 発行の関数は `/aws/lambda/ticketqr-$IMPL-tickets`、QR の関数は `/aws/lambda/ticketqr-$IMPL-get-qr`、API Gateway のアクセスログは `/aws/apigateway/ticketqr-$IMPL`（SAM で作った環境では、名前の先頭が `NamePrefix`。infra/sam/README.md 3章）

### 1.4 送るファイル

- 画像: `testdata/images/`（`photo.jpg`・`photo.png`・`photo.webp`・`photo.heic`・`photo-mif1.heif`・`photo.avif`）。画像でないもの: `testdata/images/not-image.txt`
- 大きさの境界: API は形式より先に大きさを確かめるので、ゼロで埋めたファイルでよい

  ```sh
  export WORK=$(mktemp -d)
  head -c 4194304 /dev/zero > $WORK/max.bin    # ちょうど 4MiB（大きさは通り、形式で 415）
  head -c 4194305 /dev/zero > $WORK/over.bin   # 4MiB + 1 バイト（413）
  ```

- 実機の写真: 4MB を超える写真は、高画素の設定で撮る（iPhone の 48MP の写真、Android の高画素モードなど）。手元にある 4MB 以下の写真から作るときは 3章

## 2. 各項目の手順

### 2.1 4MB 超の縮小（3.1-3） ☑ 対応済み

環境: 実機。手元（1.1）でも AWS でもよい。写った画像の向きまで見るなら、手元で解析サーバーの代わり（1.2。`PASS`）につなぐ。

| 写真 | 手順 | 期待結果 |
|---|---|---|
| 4MB を超える JPEG（iPhone・Android） | 選ぶ → 表示を見る → 「発行する」 | 「画像を縮小しています…」が出て、その間は「発行する」が押せない。縮むと「縮小しました（元の大きさ → 縮めた大きさ）」が出て、縮めた大きさは 4MB 以下。発行できる |
| 4MB を超える HEIC（iOS 17 以降） | 同上 | 同上（縮めて JPEG で送る） |
| 4MB を超える HEIC（iOS 16 以前）・HEIF（Android） | 選ぶ | 縮められず、エラーの枠に「画像のサイズが大きすぎます（4MB まで）」。「発行する」が押せない |
| 縦向きで撮った写真 | 手元で、解析サーバーの代わりにつないで発行する → `received.bin` を開く（`open -a Preview received.bin`） | 受け取った画像が、撮ったときと同じ向き（横倒しになっていない） |

- 処理時間: 選んでから「縮小しました」が出るまでを、端末ごとに計って備考に書く（目安がないので記録だけ）
- 高画素の JPEG（数千万画素〜）で、縮小が終わらない・画面が落ちる（メモリ不足）ことがないか

### 2.2 画像の大きさ超過のエラー文言（3.2-1） ☑ 対応済み

画面は送る前に `config.json` の `maxImageBytes` で大きさを確かめるので、普段は API の 413 まで届かない（画面だけで「画像のサイズが大きすぎます（4MB まで）」になる）。API の 413 の文言を出すには、**API の上限を画面の上限より小さくする**。

環境: 手元（1.1）。実機でも PC のブラウザでもよい。

```sh
# 8080 の API を止めて、上限を 1MB にして起動し直す（画面の上限は 4MB のまま）
MAX_IMAGE_BYTES=1048576 make -C go run
```

1. 1MB〜4MB の写真を選ぶ（画面の確認は通るので、「発行する」が押せる）
2. 「発行する」を押す

期待結果: API が 413 を返し、エラーの枠に「画像のサイズが大きすぎます」（数字なし）。終わったら、API を `make -C go run` で起動し直す。

あわせて、画面の確認で出る文言も見る: 4MB を超え、縮められない写真（2.1 の 3 行目）で「画像のサイズが大きすぎます（4MB まで）」。

### 2.3 30 秒のタイムアウト、通信の失敗（3.2-5）

> 本番環境（AWS）で確かめる手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md)。ここは手元での手順。

環境: 手元（1.1・1.2）。実機でも PC のブラウザでもよい。

**通信の失敗**

1. 画面を開いて写真を選ぶ
2. 端末を機内モードにする（PC ではデベロッパーツールのネットワークのタブで「オフライン」）
3. 「発行する」を押す

期待結果: すぐにエラーの枠に文言が出て、「発行する」がもう一度押せる。機内モードを戻して押すと発行できる。

**30 秒のタイムアウト**

```sh
python3 fake_analyzer.py hang 9000
# API が 30 秒を超えて待つように、解析サーバーを待つ時間を長くする
ANALYZER_MODE=http ANALYZER_URL=http://127.0.0.1:9000/v1/analyze ANALYZER_TIMEOUT_MS=60000 make -C go run
```

1. 写真を選んで「発行する」を押す
2. 時間を計る

期待結果: 「送信中…」のまま約 30 秒たつと、エラーの枠に文言が出て、もう一度押せる。

- AWS では、API Gateway が 29 秒で打ち切って先に応答を返すので、画面の 30 秒のタイムアウトは起きない（そのときは API Gateway の応答のエラーとして同じ文言になる）。30 秒のタイムアウトそのものは手元で確かめる

### 2.4 エラー 413 / 415 / 422 / 502 / 504 の JSON（3.3-2）

> 本番環境（AWS）で確かめる手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md)。ここは手元での手順。

環境: 手元（1.1・1.2）。413・415 は AWS でも確かめられる。422・502・504 は、AWS の解析サーバー（スタブ）が判定を切り替えられないので手元で確かめる。

```sh
# $1 = 送り先、$2 = ファイル
send() { curl -s -H 'Accept: application/json' -F "image=@$2" "$1/v1/tickets" -w ' -> %{http_code}\n'; }

send http://localhost:8080 $WORK/over.bin                         # 413 PAYLOAD_TOO_LARGE
send http://localhost:8080 testdata/images/not-image.txt          # 415 UNSUPPORTED_MEDIA_TYPE

# 解析サーバーの代わり（1.2）を、判定ごとに起動し直してから送る
send http://localhost:8080 testdata/images/photo.jpg              # REJECT  → 422 IMAGE_REJECTED
send http://localhost:8080 testdata/images/photo.jpg              # RETRY   → 422 IMAGE_RETRY
send http://localhost:8080 testdata/images/photo.jpg              # error   → 502 ANALYSIS_UPSTREAM_ERROR
send http://localhost:8080 testdata/images/photo.jpg              # garbage → 502 ANALYSIS_UPSTREAM_ERROR
send http://localhost:8080 testdata/images/photo.jpg              # hang    → 504 ANALYSIS_TIMEOUT（ANALYZER_TIMEOUT_MS=1000 なら約 2 秒。1 回やり直すため）
send http://localhost:8080 testdata/images/photo.jpg              # 解析サーバーの代わりを止めた状態 → 502 ANALYSIS_UPSTREAM_ERROR
```

期待結果: どれも本文が `{"error":{"code":"…","message":"…"}}` の JSON で、コードとステータスが上のとおり。

**AWS（Lambda に届かない大きさ）**: web/DEPLOY.md 12章の手順で、5MB・11MB のファイルを `$BASE/v1/tickets` に送り、ステータスと本文を記録する（期待値は未定。結果を見て決める）。

### 2.5 画像の形式の判別、4MiB の上限（3.3-3）

> 本番環境（AWS）で確かめる手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md)。ここは手元での手順。

環境: 手元（1.1。`http://localhost:8080`）か AWS（`$BASE`）。

```sh
for f in photo.jpg photo.png photo.webp photo.heic photo-mif1.heif photo.avif not-image.txt; do
  printf '%s: ' $f; send $BASE testdata/images/$f
done
send $BASE $WORK/max.bin    # ちょうど 4MiB
send $BASE $WORK/over.bin   # 4MiB + 1 バイト
```

期待結果:

| ファイル | 結果 |
|---|---|
| 6 つの画像 | 201（解析サーバーが `PASS` を返す環境） |
| `not-image.txt` | 415 `UNSUPPORTED_MEDIA_TYPE` |
| `max.bin`（ちょうど 4MiB） | 415（大きさは通り、画像でないので形式で断られる） |
| `over.bin`（4MiB + 1 バイト） | 413 `PAYLOAD_TOO_LARGE` |

- 拡張子を変えただけのファイル（例: `not-image.txt` を `x.jpg` にしたもの）も 415 になる（形式は中身で判別する）

### 2.6 ブラウザと OS の情報のログ（3.3-7） ☑ 対応済み

環境: 実機と AWS（Client Hints は HTTPS でしか届かないので、AWS の画面を使う）。

1. iPhone（Safari）と Android（Chrome）で `$WEB_URL` を開き、それぞれ 1 回発行する
2. ログを見る

```sh
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 15m --filter-pattern '"request completed"'
# OS・ブラウザごとの件数にまとめる
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 15m --filter-pattern '"request completed"' \
  | python3 scripts/client_log_summary.py
```

期待結果: 発行の要求（`"endpoint":"grant"`）のログに `client` があり、`userAgent` が端末のもの。Android の Chrome では `secChUa`・`secChUaMobile`・`secChUaPlatform`（`"Android"`）もある（iPhone の Safari は Client Hints を送らないので `userAgent` だけ）。QR の要求（`get-qr`）のログには `client` がない。

- 手元でも、`make -C go run` の端末に出るログで `client` の `userAgent` までは確かめられる

### 2.7 `Cache-Control: no-store`（3.3-8）

> 本番環境（AWS）で確かめる手順は [PROD_VERIFICATION.md](PROD_VERIFICATION.md)。ここは手元での手順。

環境: 手元（`http://localhost:8080`）か AWS（`$BASE`）。

```sh
# ヘッダーだけを見る
hdr() { grep -iE '^(HTTP/|cache-control:|x-content-type-options:|content-type:)'; }

# 発行の 201
curl -s -D - -o $WORK/ticket.json -H 'Accept: application/json' -F image=@testdata/images/photo.jpg $BASE/v1/tickets | hdr
# 発行のエラー（415）
curl -s -D - -o /dev/null -H 'Accept: application/json' -F image=@testdata/images/not-image.txt $BASE/v1/tickets | hdr
# QR 画像の 200
QR=$(python3 -c 'import json;print(json.load(open("'$WORK'/ticket.json"))["qrUrl"])')
curl -s -D - -o /dev/null "$QR" | hdr
# QR 画像の 403（sig を壊す）
curl -s -D - -o /dev/null "${QR%sig=*}sig=xxxxxxxxxxxxxxxxxxxxxx" | hdr
```

期待結果: 4 つとも `cache-control: no-store` と `x-content-type-options: nosniff` がある。

- ブラウザで確かめるときは、デベロッパーツールのネットワークのタブで、`/v1/tickets` と `…/qr?sig=…` の要求を選び、応答のヘッダーを見る

### 2.8 再読み込み・後で開く（3.4-2） ☑ 対応済み

環境: 実機（手元か AWS）。発行しないことの確認は、手元ではサーバーのログ、AWS では CloudWatch で行う。

1. 発行して、チケット画面（`#/tickets/{コード}?sig={sig}`）を出す。URL を控える
2. 画面を再読み込みする
3. ブラウザのタブを閉じ、控えた URL を開き直す（ブックマークや、別の時間に開いてもよい）

期待結果: 2・3 とも同じ QR が出る。発行の記録は 1 回分だけ。

```sh
# AWS: 発行の記録（"ticket issued"）が 1 件だけで、再読み込みのたびに増えない
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 15m --filter-pattern '"ticket issued"'
# 再読み込みのたびに、QR の関数（get-qr）のログは増える
aws logs tail /aws/lambda/ticketqr-$IMPL-get-qr --since 15m --filter-pattern '"request completed"'
```

- 手元では、`make -C go run` の端末で、`"msg":"ticket issued"` が 1 行だけで、再読み込みのたびに `"endpoint":"get-qr"` だけが増えることを見る
- PC のブラウザでは、デベロッパーツールのネットワークのタブで、再読み込みのときに `POST /v1/tickets` がなく、`GET …/qr?sig=…` だけがあることも見られる

### 2.9 QR 画像 API（3.4-4） ☑ 対応済み

環境: 手元か AWS。2.7 の続き（`$QR` に発行で返った `qrUrl` が入っている状態）。

```sh
curl -s -o $WORK/qr.png -w '%{http_code} %{content_type}\n' "$QR"     # 200 image/png
file $WORK/qr.png                                                      # PNG image data, 256 x 256
open $WORK/qr.png                                                      # 端末の QR の読み取りで、コードが読める

# 403 になるもの（本文は {"error":{"code":"FORBIDDEN",...}}）
curl -s -w ' %{http_code}\n' "${QR%sig=*}sig=xxxxxxxxxxxxxxxxxxxxxx"   # sig を壊す
curl -s -w ' %{http_code}\n' "${QR%\?sig=*}"                            # sig を消す
OTHER=$(python3 -c 'import json;print(json.load(open("'$WORK'/ticket.json"))["ticketCode"])' | sed 's/^./9/')
curl -s -w ' %{http_code}\n' "${QR%/v1/tickets/*}/v1/tickets/$OTHER/qr?${QR#*\?}"   # 別のコードに同じ sig
```

期待結果: 1 つ目は 200・`image/png`・256×256 の PNG で、読み取るとコード（`ticketCode`）になる。2〜4 つ目は 403 で、本文が `FORBIDDEN` の JSON。

### 2.10 ルートの振り分け（3.5-2） ☑ 対応済み

環境: 手元か AWS。どの関数に届いたかは、AWS ではそれぞれのロググループで見る。

```sh
send $BASE testdata/images/photo.jpg                                    # POST /v1/tickets → 201
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' "$QR"          # GET …/qr → 200 image/png
curl -s -o /dev/null -w '%{http_code}\n' $BASE/v1/unknown              # 定義のないパス → 404

# AWS: 発行は tickets の関数、QR は get-qr の関数のログに出る
aws logs tail /aws/lambda/ticketqr-$IMPL-tickets --since 10m --filter-pattern '"request completed"'   # "endpoint":"grant"
aws logs tail /aws/lambda/ticketqr-$IMPL-get-qr --since 10m --filter-pattern '"request completed"'   # "endpoint":"get-qr"
```

期待結果: 上のとおりのステータス。`tickets` のログには `grant` だけ、`get-qr` のログには `get-qr` だけが出る。

- 統合の構成で `/v1/unknown` を CloudFront 経由で送ると、API Gateway の 404 がそのまま返る（CloudFront がエラーを置き換えない）
- 実機・PC のブラウザでは、発行してチケット画面に QR が出れば、両方のルートが動いている。デベロッパーツールのネットワークのタブで、`POST /v1/tickets`（201）と `GET …/qr`（200）を見る

### 2.11 CSP（3.5-7） ☑ 対応済み

環境: AWS（CSP は CloudFront が付ける。手元の開発サーバーには付かない）。

```sh
curl -sI $WEB_URL/ | grep -i '^content-security-policy'
```

期待結果（統合の構成。`web.yaml`）:

```
default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'
```

（`form-action` は `web.yaml` のパラメータ `FormActionSource`。既定は `'none'` で、フォーム送信方式の環境だけ変える。直接の構成では、`img-src`・`connect-src` に API の URL が加わる）

縮小が CSP で止まらないこと:

1. PC の Chrome で `$WEB_URL` を開き、デベロッパーツールのコンソールを開いておく
2. 4MB を超える写真を選ぶ
3. 「縮小しました」が出たら「発行する」を押す

期待結果: 縮小と発行ができ、コンソールに CSP の違反（`Refused to load …`、`Content Security Policy`）が出ない。

- 実機（iPhone）で見るときは、Mac の Safari の Web インスペクタを iPhone につないでコンソールを見る（iPhone の設定 → Safari → 詳細 → Web インスペクタ）

## 3. 4MB を超える画像を作って確かめる

判定が通ることが分かっている 4MB 以下の写真から、4MB を超える画像を作る。それを画面で選んで縮小させ、実際の環境の判定で発行できる（`PASS`）ことを確かめる（2.1 の補い）。

### 3.1 作り方の比較

| 方法 | 中身 | 縮小した後に解析サーバーに届く画像 | 向いている確認 |
|---|---|---|---|
| A. 画素数を増やす（拡大） | 長辺を大きくして、JPEG に書き直す（例: 3000px → 7000px） | 長辺 4096px 以下に縮めた JPEG。元の写真を拡大して縮めたものなので、元とほぼ同じ見た目 | **高画素の端末の写真に近い**。縮小の段階（長辺 4096 → 2048）が実際に動く。推奨 |
| B. 画質を上げる | 画素数は同じで、JPEG の画質を 100 にする | 元と同じ画素数の JPEG（4096px 以下なら長辺はそのまま） | 元の写真が大きめ（2〜3MB）なら、これだけで 4MB を超えることがある |
| C. PNG にする | 画素数は同じで、PNG（劣化なし）にする。写真の PNG は JPEG の数倍の大きさになる | JPEG に変えたもの | 形式が変わるケース（スクリーンショットなど）の確認 |
| D. 詰め物を足す | 画素は変えず、ファイルに読み飛ばされるデータを足す（JPEG のコメント、PNG の補助チャンク） | 元と同じ画素数で、書き直しただけの JPEG。**元に最も近い** | 判定への影響を最も小さくして、縮小と送信の流れだけを確かめる |
| E. ノイズを足す | 細かい粒を足して、圧縮されにくくする | ノイズの入った画像 | 判定が変わるおそれがあるので、勧めない |

- どの方法でも、画面は JPEG（画質 0.9 から）に書き直して送る。元のファイルのバイト列がそのまま届くわけではない（縮小の仕組みは web/notes/image-compression.md）
- A で長辺を 4096px を超えて大きくすると、縮めるときに 4096px 以下に戻る。画素数を大きくしすぎると（数千万画素〜）、古い端末で縮小に時間がかかったり、メモリが足りなくなったりする。実際の高画素の端末（48MP = 8064×6048）を超えない大きさにする

### 3.2 Go の道具（`go/cmd/upsize`）

A・B・C・D を 1 つで行う。標準のライブラリと `golang.org/x/image` だけで動く（入力は JPEG・PNG・WebP。HEIC は、先に sips で JPEG にする）。

```sh
cd docs/st/go
go run ./cmd/upsize -in ~/photo.jpg -out ~/big.jpg                        # A: 5MiB を超えるまで拡大（JPEG、画質 95）
go run ./cmd/upsize -in ~/photo.jpg -out ~/big.jpg -target 8MiB -quality 98
go run ./cmd/upsize -in ~/photo.jpg -out ~/big.png -format png            # C（＋必要なら拡大）: PNG
go run ./cmd/upsize -in ~/photo.jpg -out ~/pad.jpg -mode pad              # D: 詰め物だけ（画素と EXIF はそのまま）
```

| オプション | 既定 | 内容 |
|---|---|---|
| `-mode` | `scale` | `scale`（A・B・C。長辺を 1.25 倍ずつ大きくして、`-target` を超えたら止める。元の大きさのままで超えれば拡大しない）/ `pad`（D） |
| `-target` | `5MiB` | これを超える大きさにする。`5MiB`・`6MB`・`4194305` のように書く |
| `-format` | `jpeg` | `scale` の出力の形式。`jpeg` / `png` |
| `-quality` | `95` | `scale` で JPEG にするときの画質（B は `-quality 100`） |
| `-max-edge` | `8192` | `scale` で大きくする長辺の上限。ここまで大きくしても超えなければエラー（画質を上げるか、`pad` を使う） |

- 写真の向き: スマートフォンの写真は、画素は横向きのまま EXIF の Orientation で向きを指定していることが多い。`scale` は書き直す前に、その向きを画素に反映する（書き直すと EXIF が消えるため）。`pad` は元のバイト列を変えないので、EXIF も残る
- 出力の最後に、形式・画素数・大きさを出す（例: `big.jpg: jpeg 7324×7324, 7043881 bytes (6.7MB)。元は 1659591 bytes`）

### 3.3 macOS の道具

**sips（macOS に最初から入っている）**

```sh
# A: 長辺を 7000px にして、画質 100 の JPEG にする（-Z は長辺の大きさ。拡大もする）
sips -Z 7000 -s formatOptions 100 photo.jpg --out big.jpg
# B: 画素数はそのままで、画質 100
sips -s formatOptions 100 photo.jpg --out big.jpg
# C: PNG にする
sips -s format png photo.jpg --out big.png
# HEIC を JPEG にする（Go の道具の入力にするとき）
sips -s format jpeg photo.heic --out photo.jpg
# 大きさと画素数を見る
ls -l big.jpg; sips -g pixelWidth -g pixelHeight big.jpg
```

- `-Z` の値は、出力の大きさを見て調整する（例: 3000px・画質 85 の 1.6MB の画像を、長辺 8000px・画質 100 にすると 36MB になった。大きくしすぎない）
- sips は EXIF の向きを扱うので、向きのずれは起きにくい

**プレビュー（アプリ）**: 「ツール」→「サイズを調整」で幅と高さを大きくし、「ファイル」→「書き出す」で JPEG の品質を最高にする。1 枚だけ作るならこれでもよい

**ImageMagick（`brew install imagemagick`。入っていない）**: A は `magick photo.jpg -resize 250% -quality 98 big.jpg`、E は `magick photo.jpg -attenuate 0.3 +noise Gaussian -quality 95 big.jpg`。sips でできないこと（ノイズ）が要るときだけ

### 3.4 確かめる手順

1. 判定が通ることが分かっている写真（4MB 以下）を用意し、3.2 か 3.3 で 4MB を超える画像を作る（まず A。必要に応じて D も）
2. 作った画像をスマートフォンに送る（AirDrop、または iCloud Drive・Google ドライブに置いて「ファイル」から選ぶ）。写真のアプリに保存すると形式が変わることがあるので、「ファイル」から選ぶ
3. 実際の環境の画面で、作った画像を選ぶ

期待結果: 「画像を縮小しています…」→「縮小しました（元の大きさ → 4MB 以下）」が出て、「発行する」で発行でき、チケット画面に QR が出る（判定が `PASS`）。縮小にかかった時間を備考に書く。

- 判定が `REJECT` / `RETRY` になったら、縮小で画質が落ちて判定が変わったおそれがある。D（詰め物）で作った画像でも同じかを見る。D で通り、A で通らないなら、縮小の段階（画質・長辺）を見直す材料になる（web/notes/image-compression.md 7.2 の「縮めた写真で足りるか」）
- 解析サーバーに届いた画像そのものを見たいときは、手元で解析サーバーの代わり（1.2）につないで発行し、`received.bin` を開く（`open -a Preview received.bin`）

手元での確認（2026-10-15）: 1.6MB・3000×3000 の JPEG から、A（画質 100 → 3750×3750・5.3MB）、C（3000×3000・10.8MB の PNG）、D（5.0MB）を作り、PC の Chrome で手元の画面に選んだ。どれも「縮小しました」（1.1〜1.4MB）が出て、発行してチケット画面に移った（解析サーバーは常に `PASS` の mock）。

