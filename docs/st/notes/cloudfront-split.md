# 【提案】CloudFront の定義を Web のバケットから分ける

> 提案（2026-10-06。未実装）。採用が決まったら、テンプレート（`infra/cloudformation/`）、[../web/DEPLOY.md](../web/DEPLOY.md)、[../CD_CI.md](../CD_CI.md) に反映し、このファイルは削除する。

## 1. 背景

今の `infra/cloudformation/web.yaml` は、S3 のバケットと CloudFront（OAC、セキュリティヘッダー）を1つのスタックにまとめている。次の2つの理由で、分けた方がよい。

| 理由 | 内容 |
|---|---|
| テスト環境に CloudFront は大げさ | AWS 上の E2E（CD_CI.md 0.5 の E2）や開発用の環境では、SPA が配信できれば十分。CloudFront は作成・反映に時間がかかり（十数分）、環境を作っては消す用途に向かない |
| 本番では、SPA と API を1つの CloudFront にまとめる選択肢がある | `/*` を S3、`/v1/*` を API Gateway に振り分けると、SPA と API が**同じオリジン**になる。CORS が要らなくなり、CSP も単純になり、WAF や独自ドメインを1か所で管理できる。この CloudFront は Web だけのものではなくなるので、Web のスタックに置くのは不自然 |

## 2. 提案: 3つのテンプレートに分ける

| テンプレート（スタック） | 中身 | 作る環境 |
|---|---|---|
| `api.yaml`（`ticketqr-{impl}`。今のまま） | API Gateway と Lambda。出力に **execute-api のドメイン**（`ApiDomain`）を足す | すべて |
| **`web-bucket.yaml`**（`ticketqr-web-{impl}`。`web.yaml` から S3 の部分を分ける） | SPA を置く S3 のバケット。パラメータ `Hosting` で配信の方式を選ぶ | すべて |
| **`edge.yaml`**（`ticketqr-edge-{impl}`。新規。`web.yaml` から CloudFront の部分を分けて広げる） | CloudFront、OAC、セキュリティヘッダー、バケットポリシー。パラメータ `ApiOriginDomain` を指定すると `/v1/*` を API に振り分ける | 本番（と、本番に近い検証環境） |

### 2.1 `web-bucket.yaml` の `Hosting`

| 値 | 内容 | 使う環境 |
|---|---|---|
| `cloudfront`（既定） | 非公開のバケット。読み取りは `edge.yaml` のバケットポリシー（OAC）でだけ許す | 本番 |
| `s3-website` | S3 の静的ウェブサイトホスティング（`http://{バケット}.s3-website-{リージョン}.amazonaws.com`）。バケットを公開で読み取れるようにする | テスト・開発 |

- `s3-website` は HTTP だけで、セキュリティヘッダー（CSP など）も付かない。テスト・開発の環境に限る。アカウント全体の「パブリックアクセスのブロック」が有効だと使えないので、テスト用のアカウントで許可しておく
- バケットポリシーを `edge.yaml` 側に置くのは、ポリシーに CloudFront のディストリビューションの ARN が要るため（バケットのスタックと CloudFront のスタックが互いに参照し合わないようにする）

### 2.2 `edge.yaml` の振り分け

| パス | オリジン | キャッシュ | 備考 |
|---|---|---|---|
| `/v1/*`（`ApiOriginDomain` を指定したときだけ） | API Gateway（execute-api のドメイン。HTTPS） | しない（マネージドの `CachingDisabled`） | オリジンへのリクエストは `AllViewerExceptHostHeader`（Host は execute-api のものにする。ほかのヘッダー・クエリ・ボディはそのまま）。メソッドは GET・POST などすべて許可 |
| `/*`（既定） | S3（OAC） | する（`CachingOptimized`） | 既定のルートオブジェクトは `index.html` |

主なパラメータ: `BucketName`（`web-bucket.yaml` の出力）、`ApiOriginDomain`（空なら S3 だけ）、`FormActionSource`、`PriceClass`、独自ドメインを使う場合の `Aliases` と `AcmCertificateArn`（us-east-1）。

## 3. 環境ごとの構成

| 構成 | 環境 | 構成要素 | SPA と API のオリジン | CORS | CSP |
|---|---|---|---|---|---|
| **T: テスト・開発** | AWS 上の E2E、開発用 | `api.yaml` + `web-bucket.yaml`（`s3-website`）。CloudFront なし | 別（`http://…s3-website…` と `https://…execute-api…`） | 必要（`AllowOrigins` に S3 のウェブサイトの URL） | なし（S3 は付けない） |
| S: 本番（オリジンを分ける） | 本番 | `api.yaml` + `web-bucket.yaml`（`cloudfront`）+ `edge.yaml`（S3 だけ） | 別（CloudFront と execute-api） | 必要（今の web/DEPLOY.md 5章と同じ） | `connect-src 'self' {API}`、`img-src 'self' data: {API}`（今と同じ） |
| **U: 本番（1つの CloudFront にまとめる）** | 本番（推奨） | `api.yaml` + `web-bucket.yaml`（`cloudfront`）+ `edge.yaml`（S3 と `/v1/*`） | **同じ**（CloudFront のドメイン、または独自ドメイン） | **不要** | `connect-src 'self'`、`img-src 'self' data:`、フォーム送信方式を使うなら `form-action 'self'` |

### 3.1 構成 U（1つの CloudFront）で変わること

| 項目 | 内容 |
|---|---|
| SPA の `config.json` | `apiBaseUrl` を `""`（同じオリジン）にする。SPA は対応済み（`""` は同じオリジンの意味） |
| API の `PublicBaseUrl` | CloudFront のドメイン（または独自ドメイン）にする。QR 画像の URL、チケット表示ページへのリダイレクト先が、同じオリジンの URL になる |
| CORS | 要らない（web/DEPLOY.md 5章の `update-api` は不要） |
| Origin の照合（`ALLOWED_ORIGINS`。未実装） | 許可するのは CloudFront のドメインだけになる |
| WAF | CloudFront に付けられる（HTTP API には直接付けられない。DEPLOY.md 4章の課題が解ける）。レート制限を SPA と API で1か所にまとめられる |
| 独自ドメイン | CloudFront に1つ付けるだけ（API Gateway 側の独自ドメインは要らない） |
| CloudFront を通らないアクセス | execute-api の URL は、CloudFront を通さずにも呼べる（WAF を迂回できる）。防ぐなら、CloudFront がオリジンに付ける秘密のヘッダーを API 側で確かめるか、API Gateway 側にも独自ドメインを付けて `DisableExecuteApiEndpoint` を有効にする（どちらも追加の作業） |

### 3.2 構成 T（テスト・開発）で変わること

| 項目 | 内容 |
|---|---|
| 作成の速さ | CloudFront がないので、スタックの作成・削除が早い。E2E のたびに作って消す使い方もできる |
| 確かめられないこと | CloudFront のセキュリティヘッダー（CSP など）、キャッシュ、OAC、HTTPS での SPA（Client Hints は HTTPS のページからしか届かない場合がある） |
| CSRF のテスト（E2E のケース9） | 攻撃者を想定した2つ目のオリジンを、**もう1つの `s3-website` のバケット**で安く作れる（CD_CI.md 0.5 で課題にしていた点が解ける） |

## 4. デプロイの順番（構成 U）

API と CloudFront が互いの URL を必要とするので、初回だけ API を2回デプロイする。

1. `api.yaml`（`PublicBaseUrl` は空のまま）→ 出力 `ApiDomain`（execute-api のドメイン）
2. `web-bucket.yaml`（`Hosting=cloudfront`）→ 出力 `BucketName`
3. `edge.yaml`（`BucketName`、`ApiOriginDomain`）→ 出力 `EdgeUrl`（CloudFront のドメイン）
4. `api.yaml` をもう一度（`PublicBaseUrl=$EDGE_URL`）
5. SPA と `config.json`（`apiBaseUrl: ""`）をバケットに置き、CloudFront のキャッシュを消す

独自ドメインを使う場合は、URL が先に決まるので、1 から `PublicBaseUrl` に独自ドメインを入れれば1回で済む。

## 5. 今の `web.yaml` からの移行

- `web.yaml` を `web-bucket.yaml` と `edge.yaml` に分ける。論理 ID が変わるため、バケットと CloudFront は作り直しになる（まだ利用者がいない今のうちに行うのがよい）
- 手順書（web/DEPLOY.md）は、構成 T・S・U ごとの手順にする。CI/CD（CD_CI.md）の buildspec は、環境ごとに構成を選べるようにする（例: 環境変数 `EDGE_MODE=none|split|unified`）
- E2E を AWS 上で流す（CD_CI.md 0.5 の E2）ときは、構成 T を使う

## 6. 決めること

1. この分け方（`web-bucket.yaml` と `edge.yaml`）にするか
2. 本番を構成 U（1つの CloudFront。推奨）にするか、S（オリジンを分ける。今の設計）にするか
3. 構成 U の場合、CloudFront を通らない API へのアクセスを防ぐか（防ぐなら、秘密のヘッダーか、API Gateway の独自ドメイン + `DisableExecuteApiEndpoint`）
4. テスト・開発の環境で S3 の公開のウェブサイトを使ってよいか（アカウントのパブリックアクセスのブロックの設定）
