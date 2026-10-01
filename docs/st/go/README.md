# チケットQR発行API（Go 実装）

設計は [../DESIGN.md](../DESIGN.md) を参照。

## ローカル実行

```sh
make run            # http://localhost:8080/
```

`go/cmd/local` は、HTTP リクエストを API Gateway HTTP API（payload v2）のイベントに変換して、Lambda と同じハンドラを呼び出す。
ブラウザで `http://localhost:8080/` を開くと、パターン B-1 を試すためのアップロードフォームが表示される（このフォームはローカル専用）。

```sh
# パターンA
curl -s -X POST localhost:8080/v1/tickets/qr-inline \
  -H 'content-type: application/json' \
  -d "{\"image\":\"$(base64 < sample.jpg)\"}"

# パターンB（303 → view → qr）
curl -sL -F image=@sample.jpg localhost:8080/v1/tickets
```

## テスト / ビルド

```sh
make test           # go vet + go test（共通テストベクタ ../testdata を使用）
make build          # bin/<func>.zip（provided.al2023 / arm64 用の bootstrap を含む）
```

## 環境変数

| 変数 | 必須 | 内容 |
|---|---|---|
| `PUBLIC_BASE_URL` | ○ | リダイレクト先と `<img src>` に使う絶対URL。例: `https://api.example.com` |
| `ANALYZER_MODE` | ○ | 画像解析クライアントの種類。現在選べるのは `mock`（常に valid を返す）だけ |
| `SIGNING_SALT_SECRET_ID` | ○ | 署名用 salt を保存した Secrets Manager のシークレット。中身は `{"current":"...","previous":"..."}` 形式 |
| `TICKET_SUFFIX_LENGTH` | | suffix の桁数（既定値 10） |
| `APP_ENV` / `SIGNING_SALT` | | `APP_ENV=local` のときに限り、`SIGNING_SALT` に平文で書いた salt を使う（ローカル専用） |

`make run` は、ローカル用の値（`APP_ENV=local`、`ANALYZER_MODE=mock` など）を自動で設定する。

## Lambda ハンドラ対応

| 関数 | ルート |
|---|---|
| `issue-inline` | `POST /v1/tickets/qr-inline` |
| `issue` | `POST /v1/tickets` |
| `get-view` | `GET /v1/tickets/{ticketCode}/view` |
| `get-qr` | `GET /v1/tickets/{ticketCode}/qr` |

API Gateway の設定で、`multipart/form-data` と `image/png` をバイナリとして扱わせる必要はない。HTTP API の payload v2 では、イベント側で `isBase64Encoded` が自動で付くため。
