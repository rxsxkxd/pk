# チケットQR発行API（Go 実装）

設計は [../DESIGN.md](../DESIGN.md) を参照。

## ローカル実行

```sh
make run            # http://localhost:8080/
```

エントリポイントは `go/cmd/ticketqr` の1つだけ。Lambda 上（`AWS_LAMBDA_RUNTIME_API` が設定されている環境）ではハンドラとして起動する。それ以外ではローカル HTTP サーバーとして起動し、HTTP リクエストを API Gateway HTTP API（payload v2）のイベントに変換したうえで、`routeKey` を付けて同じハンドラを呼び出す。
ブラウザで `http://localhost:8080/` を開くと、パターン B-1 を試すためのアップロードフォームが表示される（このフォームはローカル専用）。

```sh
# パターンA
curl -s -F image=@../testdata/images/photo.jpg localhost:8080/v1/tickets/qr-inline

# パターンB（303 → view → qr）
curl -sL -F image=@../testdata/images/photo.heic localhost:8080/v1/tickets   # HEIC など他の形式も可
```

### example.com の QR（別パッケージ）

```sh
make run-example    # http://localhost:8081/v1/example/qr
```

`go/cmd/exampleqr` は、チケット系とは別のデプロイパッケージ。`https://example.com` の QR（PNG）を返すだけで、環境変数は不要。

## テスト / ビルド

```sh
make test           # go vet + go test（共通テストベクタ ../testdata を使用）
make build          # bin/ticketqr.zip（チケット系4エンドポイント）と bin/exampleqr.zip。どちらも provided.al2023 / arm64 用の bootstrap
```

## 環境変数

| 変数 | 必須 | 内容 |
|---|---|---|
| `PUBLIC_BASE_URL` | ○ | リダイレクト先と `<img src>` に使う絶対URL。例: `https://api.example.com` |
| `ANALYZER_MODE` | ○ | 画像解析クライアントの種類。`mock`（通信せず常に valid）/ `http`（`ANALYZER_URL` に画像をそのまま POST。1回5秒でタイムアウトし、5xx・タイムアウト・通信エラーのときだけ1回リトライ） |
| `ANALYZER_URL` | http のとき ○ | 画像解析サーバーの POST 先（例: `http://localhost:8090/v1/analyze`） |
| `ANALYZER_API_KEY_PARAMETER_NAME` | | API キーの Parameter Store の SecureString の名前（任意。指定したときだけ `x-api-key` を付ける。VPC 内でセキュリティグループだけで許可する解析サーバーでは不要）。ローカルでは代わりに `APP_ENV=local` + `ANALYZER_API_KEY` |
| `ANALYZER_TIMEOUT_MS` | | 1回の呼び出しのタイムアウト（既定 5000） |
| `SIGNING_SALT_PARAMETER_NAME` | ○ | 署名用 salt を保存した Parameter Store の SecureString の名前（例: `/ticketqr/go/signing-salt`）。中身は `{"current":"...","previous":"..."}` 形式 |
| `TICKET_SUFFIX_LENGTH` | | suffix の桁数（既定値 8。根拠は DESIGN.md 4章） |
| `APP_ENV` / `SIGNING_SALT` | | `APP_ENV=local` のときに限り、`SIGNING_SALT` に平文で書いた salt を使う（ローカル専用） |

`make run` は、ローカル用の値（`APP_ENV=local`、`ANALYZER_MODE=mock` など）を自動で設定する。

## ルーティング

パッケージは1つで、`handler.Route` がイベントの `routeKey` を見てハンドラを選ぶ。API Gateway の統合先は、1つの関数にまとめても、ルートごとに関数を分けてもよい（どちらでもコードの変更は不要）。CloudFormation では、同じ zip を使う関数を2つ作っている。`tickets`（A / B-1 / B-3: 画像解析・採番・ビュー）と、`get-qr`（B-2: QR 生成）。QR 生成を、画像解析の同時実行数の上限から切り離すため。

| 関数（CloudFormation） | ルート |
|---|---|
| `tickets` | `POST /v1/tickets/qr-inline`、`POST /v1/tickets`、`GET /v1/tickets/{ticketCode}/view` |
| `get-qr` | `GET /v1/tickets/{ticketCode}/qr` |
| `example-qr`（exampleqr.zip。別テンプレート `example.yaml`・別 HTTP API。[DEPLOY.md](DEPLOY.md) 6章） | `GET /v1/example/qr` |

API Gateway の設定で、`multipart/form-data` と `image/png` をバイナリとして扱わせる必要はない。HTTP API の payload v2 では、イベント側で `isBase64Encoded` が自動で付くため。
