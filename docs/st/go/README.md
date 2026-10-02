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
curl -s -F image=@sample.jpg localhost:8080/v1/tickets/qr-inline

# パターンB（303 → view → qr）
curl -sL -F image=@sample.jpg localhost:8080/v1/tickets
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
| `ANALYZER_MODE` | ○ | 画像解析クライアントの種類。現在選べるのは `mock`（常に valid を返す）だけ |
| `SIGNING_SALT_SECRET_ID` | ○ | 署名用 salt を保存した Secrets Manager のシークレット。中身は `{"current":"...","previous":"..."}` 形式 |
| `TICKET_SUFFIX_LENGTH` | | suffix の桁数（既定値 8。根拠は DESIGN.md 4章） |
| `APP_ENV` / `SIGNING_SALT` | | `APP_ENV=local` のときに限り、`SIGNING_SALT` に平文で書いた salt を使う（ローカル専用） |

`make run` は、ローカル用の値（`APP_ENV=local`、`ANALYZER_MODE=mock` など）を自動で設定する。

## ルーティング

パッケージは1つで、`handler.Route` がイベントの `routeKey` を見てハンドラを選ぶ。API Gateway の統合先は、1つの関数にまとめても、ルートごとに関数を分けてもよい（どちらでもコードの変更は不要）。CloudFormation では、タイムアウトと同時実行数を個別に設定するために、同じ zip を使う関数を4つ作っている。

| 関数（CloudFormation） | ルート |
|---|---|
| `issue-inline` | `POST /v1/tickets/qr-inline` |
| `issue` | `POST /v1/tickets` |
| `get-view` | `GET /v1/tickets/{ticketCode}/view` |
| `get-qr` | `GET /v1/tickets/{ticketCode}/qr` |
| `example-qr`（exampleqr.zip） | `GET /v1/example/qr` |

API Gateway の設定で、`multipart/form-data` と `image/png` をバイナリとして扱わせる必要はない。HTTP API の payload v2 では、イベント側で `isBase64Encoded` が自動で付くため。
