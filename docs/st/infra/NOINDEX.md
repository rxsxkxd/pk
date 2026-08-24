# 検索エンジンに載せない設定（案）

> **状態**: 2章の 1（`X-Robots-Tag` のヘッダー）と 2（`index.html` の `meta`）は実装済み（2026-10-19。3.1〜3.3 のとおり）。CloudFront が画面の応答に付ける `X-Robots-Tag` は AWS 上で確認済み（2026-10-19）。API の応答のヘッダーと `index.html` の `meta` は手元で確認済み。3（`robots.txt`）は置いていない

## 1. 要件

- **このホスト（サイトのドメイン）が、検索エンジンに載らない**ようにする。トップのページも QR 画像の URL も、このホストの URL がひとつも検索結果に出ないこと
- 検索エンジン以外の経路（URL の共有、証明書の公開ログなど）でホストが知られることは、対象外
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
- その状態で、どこか公開の場所に URL が貼られると、中身なしで **URL だけが検索結果に載る**ことがある（Google の説明: noindex を効かせるには、robots.txt でブロックしない）。URL だけでも、**このホストが検索エンジンに載る**（要件に反する）
- 載る URL は、トップ（チケット画面の URL は `#/tickets/…` で、`#` から後ろはクローラーに渡らないので、トップの URL になる）と、QR 画像の URL（`/v1/tickets/{コード}/qr?sig={sig}`）。QR 画像の URL は、それだけで QR を表示できるので、とくに載せたくない
- そのため、取りに来させたうえで、`noindex` で断るほうが安全（どの URL も、ホストごと検索結果に出ない）

### 2.2.1 `robots.txt` を置くかどうか

- **置かなくてよい**: 今は `/robots.txt` がないので、CloudFront は S3 のエラー（403）を返す。Google などは `robots.txt` が 4xx（429 を除く）のとき「制限なし」として扱うので、ページを取りに来て `noindex` を読み、索引に載せない
- **置く価値はある**: `noindex` は検索結果に載せないための指示で、AI の学習用のクローラー（GPTBot、CCBot、ClaudeBot など）の多くは `robots.txt` で断る前提。学習に使われたくないなら、それらだけを `Disallow` にできる。「検索は取りに来てよい、学習用は来ないで」と意図もはっきりし、クローラーの 403 がログに残らなくなる
- **置くなら、検索エンジンを止めない**: `User-agent: *` に `Disallow: /` や `Disallow: /v1/` は書かない（上の理由で、このホストの URL だけが検索結果に載るおそれがある）

置く場合の中身（案）:

```
# 検索エンジン: 取りに来てよい（応答の X-Robots-Tag: noindex で、索引に載せない）
User-agent: *
Allow: /

# AI の学習用のクローラー: 断る
User-agent: GPTBot
User-agent: CCBot
User-agent: ClaudeBot
User-agent: Google-Extended
Disallow: /
```

- 断るクローラーの名前は、目的に合わせて選ぶ。`Google-Extended` は Google の AI での利用を断るための名前で、検索には影響しない
- 置き場所は `web/public/robots.txt`（ビルドでそのまま `robots.txt` になる）
- デプロイ: 今の S3 へのアップロード（web/DEPLOY.md 6章、`deploy.yml`）は、`index.html`・`config.json` 以外を 1 年キャッシュで上げる。`robots.txt` も `index.html` と同じく除外して `no-cache` で上げるように、両方の手順を直す（直さないと、後で中身を変えても長く反映されない）

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
