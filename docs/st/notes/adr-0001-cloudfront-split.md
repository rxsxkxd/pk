# ADR-0001: CloudFront の定義を Web のバケットから分け、環境ごとに配信の構成を選べるようにする

> 一時ドキュメント（ADR の下書き）。決定したら、正式な置き場所（例: `docs/st/adr/`）に移すか、内容を設計書・手順書に反映してこのファイルを削除する。詳しい検討は [cloudfront-split.md](cloudfront-split.md)。

| 項目 | 内容 |
|---|---|
| 状態 | **提案中（Proposed）** |
| 日付 | 2026-10-06 |
| 決める人 | （未定） |
| 関係する文書 | [../web/DEPLOY.md](../web/DEPLOY.md)、[../web/DESIGN.md](../web/DESIGN.md) 9章、[../CD_CI.md](../CD_CI.md) 0.5、[../E2E.md](../E2E.md)、`infra/cloudformation/web.yaml`・`api.yaml` |

## 1. 背景（Context）

- 今の `infra/cloudformation/web.yaml` は、SPA を置く S3 のバケットと CloudFront（OAC、セキュリティヘッダー）を、1つのスタックにまとめている
- AWS 上で E2E を流す環境や開発用の環境（CD_CI.md 0.5 の E2）では、SPA が配信できれば十分。CloudFront は作成・反映に十数分かかり、環境を作っては消す使い方に向かない（テスト環境には大げさ）
- 本番では、SPA（`/*`）と API（`/v1/*`）を1つの CloudFront にまとめて同じオリジンにする選択肢がある。そうすると CORS が要らなくなり、CSP が単純になり、WAF と独自ドメインを1か所で管理できる。その場合の CloudFront は Web だけのものではなくなり、Web のスタックに置くのは不自然になる
- 実際に、CSP の `connect-src` に `'self'` が足りず `config.json` が読めない不具合があった。SPA と API のオリジンが分かれていることで、CSP と CORS の設定が増えている

## 2. 決めるときに重視すること（Decision Drivers）

1. テスト・開発の環境を、早く・安く作って消せること
2. 本番で、SPA と API を同じオリジンにまとめる構成を選べること
3. CORS・CSP・WAF・独自ドメインの設定を、少なく・1か所にまとめられること
4. スタック同士が互いを参照し合わないこと（作成と削除の順番で詰まらない）
5. 今の API（`api.yaml`）と SPA の実装を、なるべく変えないこと

## 3. 検討した案（Considered Options）

| 案 | 内容 |
|---|---|
| O1: 今のまま | `web.yaml` に S3 と CloudFront をまとめたまま。テスト環境にも CloudFront を作る |
| O2: `web.yaml` に「CloudFront を作るか」のパラメータを足す | 1つのテンプレートで、条件付きで CloudFront を作る。API への振り分けも同じテンプレートに足す |
| **O3: S3（`web-bucket.yaml`）と CloudFront（`edge.yaml`）を別のテンプレートに分ける** | テスト環境は S3 だけ、本番は S3 + CloudFront。CloudFront は API への振り分け（`/v1/*`）も持てる |

| 観点 | O1 | O2 | **O3** |
|---|---|---|---|
| テスト環境の速さ・費用 | ×（毎回 CloudFront） | ○ | ◎ |
| 本番で SPA と API を1つの CloudFront にまとめる | △（Web のスタックに API の振り分けが入る） | △（同左。条件分岐が増える） | ◎（CloudFront は「入口」として独立） |
| テンプレートの見通し | ○ | ×（条件だらけになる） | ◎（役割ごとに1つ） |
| スタックの相互参照 | - | - | ○（バケットポリシーを `edge.yaml` 側に置けば一方向で済む） |
| 移行の手間 | なし | 小 | 中（バケットと CloudFront を作り直す） |

## 4. 決定（Decision）（提案）

**O3 を採る。** テンプレートを次の3つにする。

| テンプレート（スタック） | 中身 |
|---|---|
| `api.yaml`（`ticketqr-{impl}`） | 今のまま。出力に execute-api のドメイン（`ApiDomain`）を足す |
| `web-bucket.yaml`（`ticketqr-web-{impl}`） | SPA を置く S3 のバケット。パラメータ `Hosting`: `cloudfront`（非公開。既定）/ `s3-website`（テスト・開発用の公開ウェブサイト） |
| `edge.yaml`（`ticketqr-edge-{impl}`） | CloudFront、OAC、セキュリティヘッダー、バケットポリシー。`ApiOriginDomain` を指定すると `/v1/*` を API Gateway に振り分ける（キャッシュしない） |

環境ごとの構成:

| 構成 | 環境 | 構成要素 | CORS | CSP |
|---|---|---|---|---|
| T | テスト・開発（AWS 上の E2E を含む） | `api.yaml` + `web-bucket.yaml`（`s3-website`） | 必要 | なし |
| S | 本番（オリジンを分ける） | `api.yaml` + `web-bucket.yaml` + `edge.yaml`（S3 だけ） | 必要 | `'self'` + API のオリジン |
| **U** | **本番（推奨）** | `api.yaml` + `web-bucket.yaml` + `edge.yaml`（S3 と `/v1/*`） | **不要** | `'self'` だけ |

本番は構成 U を推奨する。SPA の `config.json` は `apiBaseUrl: ""`（同じオリジン。SPA は対応済み）、API の `PublicBaseUrl` は CloudFront のドメイン（または独自ドメイン）にする。

## 5. 結果（Consequences）

### 良くなること

- テスト・開発の環境に CloudFront が要らなくなり、作成・削除が早く・安くなる。E2E のたびに作って消す使い方もできる
- E2E の CSRF のテスト（ケース9）に使う「攻撃者を想定した2つ目のオリジン」を、もう1つの S3 のウェブサイトで安く作れる
- 構成 U では、CORS の設定（今の `update-api` による暫定の設定を含む）が要らなくなり、CSP も `'self'` だけで済む
- WAF を CloudFront に付けられる（HTTP API には直接付けられない課題が解ける）。独自ドメインも CloudFront に1つで済む

### 悪くなること・注意すること

- 今の `web.yaml` の論理 ID が変わるので、バケットと CloudFront は作り直しになる（利用者がいない今のうちに行う）
- 構成 U の初回は、API と CloudFront が互いの URL を必要とするため、API を2回デプロイする（独自ドメインを使えば1回）
- 構成 U でも、execute-api の URL は CloudFront を通さずに呼べる（WAF を迂回できる）。防ぐには、CloudFront の秘密のヘッダーを API 側で確かめるか、API Gateway に独自ドメインを付けて `DisableExecuteApiEndpoint` を有効にする（追加の作業）
- 構成 T の S3 のウェブサイトは HTTP だけで、セキュリティヘッダーも付かない。CSP と HTTPS の確認は、構成 S・U の環境でしかできない。また、アカウントのパブリックアクセスのブロックを、テスト用のアカウントで許可する必要がある
- 手順書（web/DEPLOY.md）と CI/CD（CD_CI.md の buildspec）を、構成 T・S・U ごとに書き分ける必要がある

## 6. 未解決の事項（Open Questions）

1. 本番を構成 U（推奨）にするか、S にするか
2. 構成 U で、CloudFront を通らない API へのアクセスを防ぐか（防ぐなら、秘密のヘッダーか、独自ドメイン + `DisableExecuteApiEndpoint`）
3. テスト・開発の環境で、S3 の公開のウェブサイトを使ってよいか（アカウントの設定）
4. 構成の選び方を、CI/CD でどう渡すか（例: 環境変数 `EDGE_MODE=none|split|unified`）
