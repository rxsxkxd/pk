# 検索エンジンに載せない設定（案）

> **状態**: 2章の 1（`X-Robots-Tag` のヘッダー）と 2（`index.html` の `meta`）は実装済み（2026-10-19。3.1〜3.3 のとおり）。手元で、API の応答（201・403）のヘッダーと `index.html` の `meta` を確かめた。CloudFront のヘッダー（3.1）は AWS 上では未確認（4章で確かめる）。3（`robots.txt` を置かない）は、置いていないのでそのまま

## 1. 要件

- 検索エンジンなどのクローラーに拾われず、**検索結果に載らない**ようにする
- **リンク（URL）を知っている人は見られてよい**。ログインや IP の制限などのアクセス制限は付けない
- インフラは今までの想定どおり AWS（CloudFront → S3 の画面、CloudFront の `/v1/*` → API Gateway → Lambda の API。統合の構成）

## 2. 方針

| 順 | 設定 | 場所 | 役割 |
|---|---|---|---|
| 1 | すべての応答に、ヘッダー `X-Robots-Tag: noindex, nofollow, noarchive` を付ける | 画面: CloudFront のレスポンスヘッダーポリシー<br>API: API の共通のヘッダー | **主の対策**。クローラーが来ても、索引に載せない・リンクをたどらない・保存版（キャッシュ）を出さない |
| 2 | `index.html` に `<meta name="robots" content="noindex, nofollow">` を入れる | `web/index.html` | 1 の予備。ヘッダーの設定が漏れた環境でも効く |
| 3 | `robots.txt` で全体のクロールを禁止（`Disallow: /`）**しない** | `robots.txt` は置かない | 2.2 |

### 2.1 API にもヘッダーを付ける理由

- 統合の構成の CloudFront では、`/v1/*`（API）の振る舞いに、画面用のレスポンスヘッダーポリシーを付けていない（`web.yaml` のコメントのとおり、API は自分で応答のヘッダーを付ける作り）。CloudFront の設定だけでは、API の応答（とくに QR 画像）に付かない
- API 自身が付ければ、CloudFront を通らない execute-api の URL で呼ばれたときにも効く

### 2.2 `robots.txt` で止めない理由

- `Disallow: /` にすると、クローラーはページを取りに来ないので、`noindex` の指示も読めない
- その状態で、どこか公開の場所に URL が貼られると、中身なしで **URL だけが検索結果に載る**ことがある（Google の説明: noindex を効かせるには、robots.txt でブロックしない）
- このシステムで載って困るのは、**QR 画像の URL**（`/v1/tickets/{コード}/qr?sig={sig}`）。この URL だけで QR を表示できる
- チケット画面の URL は `#/tickets/…` で、`#` から後ろはクローラーに渡らない（載るとしてもトップの URL だけ）
- そのため、取りに来させたうえで、`noindex` で断るほうが安全

### 2.3 今の設定で、すでに足りていること

| 設定 | 効果 |
|---|---|
| 画面の応答の `Referrer-Policy: no-referrer`（`web.yaml`）、API のチケット表示ページの `Referrer-Policy: no-referrer` | 画面から外のサイトへ移っても、チケットの URL が相手に伝わらない（URL が外に漏れる経路を減らす） |
| サイトマップを置いていない。公開のページからリンクしていない | クローラーが URL を知る経路がない |
| API の応答の `Cache-Control: no-store` | 途中のキャッシュに QR 画像や発行の結果が残らない |

## 3. 変更する箇所

### 3.1 CloudFront（画面の応答）: `infra/cloudformation/web.yaml`

今の `ResponseHeadersPolicy` の `ResponseHeadersPolicyConfig` に、カスタムヘッダーを足す。

```yaml
      ResponseHeadersPolicyConfig:
        Name: !Sub "${AWS::StackName}-headers"
        CustomHeadersConfig:
          Items:
            - Header: X-Robots-Tag
              Value: noindex, nofollow, noarchive
              Override: true
        SecurityHeadersConfig:
          # （今のまま）
```

- 反映は、Web のスタックを同じコマンドでもう一度デプロイする（web/DEPLOY.md 8章のヘッダーの変更と同じ）。キャッシュの無効化は要らない（ヘッダーは CloudFront が応答のたびに付ける）
- 手動（AWS CLI）で作った環境では、`headers.json` に同じ項目を足して、`update-response-headers-policy` で更新する（web/DEPLOY.md 4章・8章）
- `index.html`・`config.json`・`assets/*`（画像・アイコンを含む）のすべてに付く

### 3.2 API（API の応答）

すべての応答に付けている共通のヘッダーに足す。

| 場所 | 足すもの |
|---|---|
| `go/internal/httpapi/handler.go` の `withCommon` | `h["X-Robots-Tag"] = "noindex, nofollow, noarchive"` |

- 単体テストの共通のヘッダーの確認（`assertCommonHeaders`）にも足す
- 発行（201・エラー）、QR 画像（200・403）、チケット表示ページのすべてに付く

### 3.3 画面: `web/index.html`

```html
<meta name="robots" content="noindex, nofollow" />
```

`<title>` の近くに入れる。ビルドの後の `index.html` にもそのまま残る。

## 4. 確かめ方

```sh
# 画面（CloudFront → S3）
curl -sI $WEB_URL/ | grep -i '^x-robots-tag'
curl -sI $WEB_URL/config.json | grep -i '^x-robots-tag'
curl -s $WEB_URL/ | grep -o '<meta name="robots"[^>]*>'

# API（CloudFront の /v1/*）: 発行と QR 画像
curl -s -D - -o $WORK/ticket.json -H 'Accept: application/json' -F image=@$WORK/cert.jpg $WEB_URL/v1/tickets | grep -i '^x-robots-tag'
QR=$(python3 -c 'import json;print(json.load(open("'$WORK'/ticket.json"))["qrUrl"])')
curl -s -D - -o /dev/null "$QR" | grep -i '^x-robots-tag'

# API（execute-api の URL を直接）
curl -s -D - -o /dev/null "$API_URL/v1/tickets/x/qr?sig=x" | grep -i '^x-robots-tag'     # 403 でもヘッダーは付く
```

- API には `-I`（HEAD）を使わない。API のルートは GET・POST だけなので、HEAD は API Gateway の 404 になり、API のヘッダーが付かない

期待結果: どれも `x-robots-tag: noindex, nofollow, noarchive`（`meta` は `noindex, nofollow`）。`$WEB_URL/robots.txt` は置かない（S3 にないので CloudFront のエラーの応答になる）。

- 本番のデータを使わずに確かめるなら、発行の代わりに QR 画像の 403（上の最後の行と同じ形を `$WEB_URL` に向ける）で見てもよい
- 手元（`make -C go run`）では、API のヘッダー（3.2）と `index.html`（3.3）だけ確かめられる。CloudFront のヘッダー（3.1）は AWS で確かめる

## 5. 限界

- `noindex` は、クローラーへの「載せないで」というお願い。従わないクローラー（悪質なもの）は止められない
- リンクが外に漏れれば、その人は見られる（要件どおりの性質）。見られて困る場合は、アクセス制限（WAF の IP 制限、CloudFront の署名付き Cookie、ログインなど）が要る。それは今回の要件の外
- **すでに検索結果に載ってしまった**場合は、ヘッダーを付けた後に、Google Search Console などで削除を申請する。所有の確認が要るので、独自ドメインを付けた環境での手段になる（CloudFront の既定のドメイン `*.cloudfront.net` は確認できない）
- 開発用の `example.yaml`（example.com の QR）など、ほかに公開している URL があれば、同じ設定にするか決める

## 6. 決めること

1. この方針で実装するか（3.1〜3.3）
2. `noarchive` まで付けるか（付けても困ることはない見込み）
3. `robots.txt` を置かない方針でよいか（2.2）。AI の学習用のクローラーなど、`robots.txt` だけを見るものへの対策が要るなら、`Disallow` しつつ QR 画像の URL が載らないようにする方法を別に考える
