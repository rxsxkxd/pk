# 実装概要

テストで確かめる事項は、ここから外した設定の事項も含めて [TEST_SCOPE.md](TEST_SCOPE.md) にまとめている。

スマートフォンで撮った証明書の画像を送ると、画像解析サーバーで確かめたうえでチケット（QR コード）を発行し、ブラウザに表示するシステムを新しく作った。

利用者は、発行画面で証明書の画像を選び（Android は「画像を選ぶ」か「カメラを起動」）、「発行する」を押す。画像が 4MB を超えていれば、画面が送る前に縮める。API は画像を画像解析サーバーに送り、判定が `PASS` ならコードと、QR 画像の URL に付ける sig を返す。画面はチケット画面に移り、QR コードを表示する。チケット画面の URL にはコードと sig が入っていて、同じ URL を開けば何度でも同じ QR が出る。発行できなかったときは、ボタンの下に理由を出し、別の画像を選び直すか、もう一度押せる。

| 項目 | 内容 |
|---|---|
| 利用者の環境 | スマートフォンのブラウザ。iOS 13 以上 / Android 9 以上。古い端末から、最新の高スペックな端末（高画素のカメラ）まで、どちらも使われる。OS の更新や画像の作り直しなど、利用者側の対応は求めない |
| 構成 | 画面は SPA（Vue 3.5 + TypeScript）、API は Go（AWS Lambda、arm64）。画面と API は同じアドレス（CloudFront）で提供し、API は `/v1/` 以下（API Gateway → Lambda） |
| 画像解析 | 外部の画像解析サーバーに画像をそのまま送り、結果（`PASS` / `REJECT` / `RETRY`）を受け取る。発行の Lambda は VPC のプライベートサブネットに置き、NAT ゲートウェイ経由で解析サーバーにつなぐ |
| チケット | コード `{日付8桁}{時刻6桁}{UUIDv4 のハイフンなし小文字16進32桁}{固定文字列}`（日時は日本時間）と、QR 画像の URL に付ける sig（HMAC。22 文字）。API はチケットを保存しない |
| 画像の上限 | 4MiB（4,194,304 バイト）。超えた写真は、画面で縮めてから送る |

# 機能設計

## 1-1. 目的

- 利用者が、手持ちのスマートフォンで撮った証明書の画像だけで、その場でチケットを受け取れるようにする
- 証明書の確認は画像解析サーバーに任せ、結果が `PASS` のときだけチケットを発行する
- 発行したチケットは、QR コードとして画面に出し、同じ URL を開けば何度でも表示できるようにする

## 1-2. 背景

- 利用者の端末は、古い端末（iOS 13 / Android 9）から、最新の高スペックな端末まで、どちらもありうる。古いブラウザでも動き、かつ新しい端末の大きな写真も扱える作りにする必要がある
- 最新の端末の写真は大きく（高画素のカメラでは 4MB を超える）、そのままでは API の上限（Lambda の受け取れる大きさで決まる）を超えることがある。端末によって、写真の形式も違う（iPhone の HEIC、Android の JPEG・HEIF など）
- 利用者側の対応は期待できない。OS を更新してもらう、写真を縮めてもらう、スクリーンショットを撮って形式を変えてもらう、といったことができない（やり方が分からない、端末が古くて更新できないなど）可能性がある。そのため、端末が作るままの写真を、そのまま選んで送れるようにする
- 発行の記録を持つデータベースは置かない。QR 画像の URL が正しいかは、sig で確かめる

## 1-3. 確定仕様

| 操作・状態 | 仕様 |
|---|---|
| 画面を開く（どの画面も） | 画面の設定 `config.json` を読んでから表示する。読めない・形が違うときは「設定を読み込めませんでした。時間をおいて再読み込みしてください。」だけを出す。先頭にバナー（501×146px。画面の幅に合わせて縮む）を出す |
| 発行画面（`#/`）を開く | 上から、バナー、見出し「チケット発行」、説明文、画像の選択、「発行する」ボタン、（エラーの枠、）補足事項が出る。画像を選ぶまでボタンは押せない。知らない URL（`#/xxx`）は発行画面に移る |
| 発行画面で画像を選ぶ（iOS など Android 以外） | 選択欄が 1 つ。写真・カメラ・ファイルは iOS のメニューから選ぶ。選べる形式は JPEG / PNG / HEIC / HEIF / AVIF / WebP |
| 発行画面で画像を選ぶ（Android） | 「画像を選ぶ」「カメラを起動」の 2 つのボタンが縦に並ぶ（Android 14 以降は、画像の選択画面でカメラを選べないため）。「カメラを起動」は背面のカメラを直接起動する |
| 発行画面で画像を選んだ | 選んだファイルの名前と大きさが出る（プレビューは出さない）。前の API のエラーは消える |
| 発行画面で 4MB を超える画像を選んだ | 「画像を縮小しています…」と出して縮め（この間は押せない）、縮んだら「縮小しました（11.9MB → 3.4MB）」と出す。縮めた画像（JPEG）を送る。4MB 以下の画像は加工せずに送る |
| 発行画面で、縮めても 4MB に収まらない・縮められない画像（Android の HEIC など）を選んだ | エラーの枠に「画像のサイズが大きすぎます（4MB まで）」。押せない |
| 発行画面で対応していない形式を選んだ | エラーの枠に「この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）」。押せない（形式は MIME タイプか拡張子で目安として確かめ、最終的な判定は API） |
| 発行画面で「発行する」を押す | ボタンが「送信中…」になり、押せなくなる（二重発行の防止）。チケット付与 API に画像を送る。30 秒で応答がなければ打ち切る |
| チケット付与 API が要求を受けた | `POST /v1/tickets`（`multipart/form-data` の `image`、`Accept: application/json`）。画像の大きさ（4MiB 以下）を確かめ、形式を中身（先頭のバイトと、形式ごとのヘッダー）で判別し、画像解析サーバーに画像をそのまま送る。判定が `PASS` ならコードと sig を作り、`201 { ticketCode, issuedAt, sig, qrUrl }` を返す（`ticketCode` はコード、`issuedAt` は `+09:00` の日時、`sig` は 22 文字、`qrUrl` は sig 付きの QR 画像 API の URL）。チケットは保存しない。ブラウザと OS の情報（User-Agent と Client Hints）をログに残す |
| チケット付与 API で、画像解析サーバーに問い合わせる | 画像を `application/octet-stream` でそのまま送る（API キーを `X-Api-Key` に付ける）。1 回 5 秒で打ち切り、つながらない・時間切れ・5xx のときは 1 回だけやり直す。応答の `result`（`PASS` / `REJECT` / `RETRY`）だけを見る。応答はそのままログに残す |
| 解析の判定が `REJECT` | API: 422 `IMAGE_REJECTED`。発行画面のエラーの枠: 「この証明書の画像ではチケットを発行できません」 |
| 解析の判定が `RETRY` | API: 422 `IMAGE_RETRY`。発行画面のエラーの枠: 「画像をうまく確認できませんでした。明るい場所で、証明書全体が写るように撮り直してください」 |
| 解析サーバーにつながらない・5xx・応答の形が違う | API: 502 `ANALYSIS_UPSTREAM_ERROR`。発行画面のエラーの枠: 「ただいま混み合っています。時間をおいてお試しください」 |
| 解析サーバーが時間切れ | API: 504 `ANALYSIS_TIMEOUT`。発行画面のエラーの枠: 「ただいま混み合っています。時間をおいてお試しください」 |
| API に届いた画像が上限を超える | API: 413 `PAYLOAD_TOO_LARGE`。発行画面のエラーの枠: 「画像のサイズが大きすぎます」（API の上限は画面からは分からないので、数字は出さない） |
| API に届いた画像の形式が違う（`multipart/form-data` でない、画像でない、対応しない形式） | API: 415 `UNSUPPORTED_MEDIA_TYPE`。発行画面のエラーの枠: 「この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）」 |
| API に届いた要求が壊れている（`image` がない・空、`multipart` の本文が壊れている） | API: 400 `BAD_REQUEST`。発行画面のエラーの枠: 「発行できませんでした。もう一度お試しください」 |
| 通信の失敗、30 秒のタイムアウト、予期しない応答（JSON でない、形が違う）、そのほかの API のエラー | 発行画面のエラーの枠: 「発行できませんでした。もう一度お試しください」 |
| API のエラーの形 | 本文は JSON の `{ "error": { "code", "message" } }`。すべての応答に `Cache-Control: no-store` と `X-Content-Type-Options: nosniff` |
| 発行画面で発行できなかった | ボタンの下のエラーの枠（1 か所）に文言を出し、もう一度押せる。選んだ画像の問題があればそちらを先に出す。別の画像を選ぶと API のエラーは消える |
| 発行画面で発行できた | チケット画面（`#/tickets/{コード}?sig={sig}`）に移る。戻るボタンで発行の直後に戻らないよう、履歴を置き換える |
| チケット画面を開く | 上から、バナー、見出し「チケット」、QR コード、チケットの使い方の説明文、「別の証明書の画像で発行する」ボタンが出る。QR は URL のコードと sig から QR 画像 API の URL を作って読み込む。コード文字列と発行日時は画面に出さない |
| QR 画像 API が要求を受けた | `GET /v1/tickets/{コード}/qr?sig={sig}`。sig が合えば `200 image/png`（256×256px、誤り訂正レベル M、周りに余白）。sig がない・合わない・コードがないときは 403 `FORBIDDEN`（JSON）。`Cache-Control: no-store` |
| チケット画面を再読み込みする・URL を保存して後で開く | 同じ QR が出る（URL だけから描くので、再発行はされない。チケット付与 API は呼ばない） |
| チケット画面の URL の形が違う（sig がない、コード・sig の形が違う） | QR の代わりに「無効なチケット URL です」を出す（使い方の説明文は出さない）。API は呼ばない |
| チケット画面で QR を読み込めない（sig が合わない 403、通信の失敗） | QR の代わりに「無効なチケット URL です」を出す（使い方の説明文は出さない） |
| チケット画面で「別の証明書の画像で発行する」を押す | 選んだ画像と状態を消して、発行画面に戻る |

## 1-4. サービスチケット発行

### 1-4-1. 実装内容

#### API 実装

（`go/` から）

| No. | ファイル | 内容 |
|---|---|---|
| 1 | `cmd/ticketqr/main.go` | Lambda の入口。`AWS_LAMBDA_RUNTIME_API` があれば Lambda として API Gateway（HTTP API）のイベントを受けて `Route` に渡す。なければローカル用の HTTP サーバーを起動する（`local.go`） |
| 2 | `cmd/ticketqr/wire.go` | 起動時の組み立て。`config.Load` の設定と、Parameter Store の値（sig の salt、コードの固定文字列、解析サーバーの API キー）を読み、解析のクライアント（`analyzer.New`）・コードの生成器（`ticket.NewGenerator`）・sig の作成と照合（`signer.New`）を作ってハンドラ（`httpapi.Handlers`）に渡す。ログは JSON で標準出力へ |
| 3 | `internal/config/config.go` | 環境変数の読み込みと確認。`PUBLIC_BASE_URL`（QR の URL の先頭。http(s) の絶対 URL 必須）、`ANALYZER_MODE`（`http` / `mock`）、`ANALYZER_URL`（`http` のとき必須）、`ANALYZER_TIMEOUT_MS`（既定 5000）、`MAX_IMAGE_BYTES`（上限を下げるときだけ） |
| 4 | `internal/config/secret.go` | Parameter Store の値の読み込み。`SIGNING_SALT_PARAMETER_NAME`（SecureString の JSON `{"current","previous"}`）、`TICKET_CODE_SUFFIX_PARAMETER_NAME`（String）、`ANALYZER_API_KEY_PARAMETER_NAME`（SecureString）。名前がないときは環境変数の値（`TICKET_CODE_SUFFIX`、ローカル開発のときだけ `SIGNING_SALT`・`ANALYZER_API_KEY`） |
| 5 | `internal/httpapi/route.go` | ルートキーでの振り分け。`POST /v1/tickets` → `Grant`（ほかに QR 画像の `GET /v1/tickets/{ticketCode}/qr` など） |
| 6 | `internal/httpapi/handler.go` | `Grant`: `readUpload` で `multipart/form-data` の最初の `image` を読み、上限（`maxImageBytes`。`MAX_IMAGE_BYTES` と 4MiB の小さいほう）を確かめ、`imageinput.Detect` で形式を判別して `ticket.VerifyAndGrant` に渡す。`Accept` に `application/json` があれば `201 { ticketCode, issuedAt, sig, qrUrl }`（`qrUrl` = `{PUBLIC_BASE_URL}/v1/tickets/{コード}/qr?sig={sig}`）。共通のヘッダー（`Cache-Control: no-store`、`X-Content-Type-Options: nosniff`）を付ける。`run` で要求ごとに `requestId`・`endpoint`・`status`・`durationMs` と、ブラウザの情報（`userAgent`、`secChUa`、`secChUaMobile`、`secChUaPlatform`、`secChUaPlatformVersion`）をログに残す |
| 7 | `internal/httpapi/errors.go` | 発行のエラーを HTTP のステータスとエラーコードに変える（`toAPIError`）。REJECT → 422 `IMAGE_REJECTED`、RETRY → 422 `IMAGE_RETRY`、時間切れ → 504 `ANALYSIS_TIMEOUT`、解析の失敗 → 502 `ANALYSIS_UPSTREAM_ERROR`、形式違い → 415 `UNSUPPORTED_MEDIA_TYPE`、大きすぎ → 413 `PAYLOAD_TOO_LARGE`、画像がない・空・本文が壊れている → 400 `BAD_REQUEST`、それ以外 → 500 `INTERNAL_ERROR` |
| 8 | `internal/imageinput/imageinput.go` | 上限 `MaxBytes`（4MiB）と、形式の判別 `Detect`。先頭のバイトで形式を見分け、形式ごとのパーサーで画像の大きさまで読めたものだけを、その形式とする（JPEG / PNG / WebP はデコーダーのヘッダー読み取り、HEIC / HEIF / AVIF は主画像の大きさ `ispe` があること）。読めなければ `""` |
| 9 | `internal/ticket/grant.go` | 発行の中心 `VerifyAndGrant`。画像が空でないこと（`ErrEmptyImage`）、受け付ける形式（`acceptedTypes`: JPEG / PNG / HEIC / HEIF / AVIF / WebP）であること（`ErrUnsupportedImage`）を確かめ、解析サーバーに問い合わせ、`PASS` ならコードを作る。`REJECT` / `RETRY` は業務のエラー、解析の失敗は `ErrVerifierUpstream`、時間切れは `ErrVerifierTimeout` |
| 10 | `internal/ticket/code.go` | コードの生成 `Generate`。日本時間の `YYYYMMDDHHmmss`、`crypto/rand` からの UUIDv4（ハイフンなし小文字 16 進 32 桁）、固定文字列（英数字 1〜32 文字。`NewGenerator` で確かめる）をつなげる |
| 11 | `internal/ticket/verifier.go`・`errors.go` | 解析サーバーへの問い合わせの形（`Verifier` インターフェース、結果 `ResultPass` / `ResultReject` / `ResultRetry`）と、発行のエラーの定義 |
| 12 | `internal/analyzer/analyzer.go` | 解析のクライアントの選択 `New`。`ANALYZER_MODE=http` は HTTP のクライアント、`mock` は常に `PASS` を返す（開発・E2E 用） |
| 13 | `internal/analyzer/http.go` | 解析サーバーの HTTP クライアント。画像を `POST`（`Content-Type: application/octet-stream`、API キーがあれば `X-Api-Key`）。1 回ごとに `ANALYZER_TIMEOUT_MS` で打ち切り、送信の失敗・時間切れ・5xx は 1 回だけやり直す。応答の本文はそのままログに残し（2xx 以外は警告）、JSON の `result` だけを読む |
| 14 | `internal/signer/signer.go` | sig の作成 `Sign`（コードを salt で HMAC-SHA256 にかけ、base64url にした先頭 22 文字）。`Verify` は今の salt と、入れ替え中は前の salt（`previous`）でも照合する |

#### 画面表示実装

（`web/src/` から）

| No. | ファイル | 内容 |
|---|---|---|
| 1 | `main.ts` | 起動の処理 `start`。最初に `core-js/actual/object/has-own`（`Object.hasOwn` の補い）を読み、`loadConfig` で設定を読んでから、Pinia とルーターを入れて表示する。読めなければ「設定を読み込めませんでした…」 |
| 2 | `config.ts` | 実行時の設定 `config.json` の読み込み（`cache: 'no-store'`）と valibot での検証（`ConfigSchema`）。`apiBaseUrl`（`""` = 同じオリジン、または http(s) の URL。末尾の `/` は取る）、`maxImageBytes`（1〜`MAX_IMAGE_BYTES` の整数。既定 4MiB） |
| 3 | `router.ts`・`modes/page/index.ts` | hash モードのルート。`/` が発行画面（`GrantPage`）、`/tickets/:code` がチケット画面。知らないパスは `/` へ |
| 4 | `App.vue`・`components/AppBanner.vue` | 全画面の先頭のバナー（`assets/banner.png`、501×146px。今は仮の画像） |
| 5 | `modes/page/GrantPage.vue` | 発行画面。説明文、画像の選択、「発行する」ボタン（`data-testid="grant-page"`。`canSend` でないときは押せない）、エラーの枠、補足事項を並べる。押すと `store.send(grantForPage)` を呼び、成功したら `router.replace` でチケット画面へ |
| 6 | `components/GrantDescription.vue` | 発行画面の説明文（見出しと画像の選択の間。約 100 文字。文言は仮） |
| 7 | `components/CertificateImagePicker.vue` | 画像の選択。`accept` は `ACCEPT`（6 つの MIME タイプ）。Android（`isAndroid`）は「画像を選ぶ」と「カメラを起動」（`capture="environment"`）の 2 つのボタン、ほかは選択欄 1 つ。ファイル名と大きさ、縮小中（`shrinking`）・縮小の結果（`shrunkSize`）を出す |
| 8 | `platform.ts` | `isAndroid`: User-Agent Client Hints の `platform` か User-Agent に Android があるか |
| 9 | `stores/ticket.ts` | 発行の状態（Pinia）。`file`（選んだ画像）、`shrunk`（縮めた画像）、`shrinking`、`status`（`idle` / `sending` / `granted` / `failed`）、`error`。送る前の確認 `checkFile`（未選択、`maxImageBytes` 超、形式）、`canSend`、エラーの文言 `messageFor`（エラーコード → 文言）、エラーの枠に出す文言 `errorMessage`（画像の問題を先に、なければ API のエラー）。画像を選んだら前のエラーを消し、上限を超えていれば `shrinkToFit` で縮める（縮めている間に選び直したら前の結果は捨てる）。`send` は送信中の二重送信を防ぐ |
| 10 | `image/shrink.ts` | 上限を超えた写真の縮小 `shrinkToFit`（Compressor.js）。`SHRINK_STEPS`（長辺 4096・画質 0.9 → 4096・0.8 → 3072・0.8 → 2048・0.8）を順に試し、上限に収まった最初の JPEG を返す。収まらない・読めない（古い iOS の HEIC など）ときは `undefined` |
| 11 | `modes/page/api.ts` | チケット付与 API の呼び出し `grantForPage`（`{apiBaseUrl}/v1/tickets` に `Accept: application/json`）と、応答の形 `PageTicketSchema`（`ticketCode`、`issuedAt`、`sig`、`qrUrl`） |
| 12 | `api/client.ts` | API の呼び出しの共通部分 `postImage`（`FormData` の `image` を `POST`、`TIMEOUT_MS` = 30 秒で `AbortController` で打ち切り、201 は schema で、それ以外は `ApiErrorSchema` で読む）。失敗は `ApiError`（API のエラーコード、または `NETWORK` / `UNEXPECTED`）。コード・sig・発行日時の形（`TicketCode`、`Sig`、`IssuedAt`） |
| 13 | `components/ErrorMessage.vue` | エラーの枠（`role="alert"`、`data-testid="error"`） |
| 14 | `components/GrantNotes.vue` | 発行画面の補足事項（ボタンとエラーの枠の後。箇条書き。項目は配列 `notes` に足す。文言は仮。発行方式で共通） |

### 1-4-2. 実装方式

- **画面 → API**: SPA が `fetch` で `FormData`（`image`）を `POST /v1/tickets` に送る（`Accept: application/json`）。`config.json` の `apiBaseUrl` が `""` なので相対パスになり、CloudFront の `/v1/*` を通って API Gateway に届く（同じオリジンなので CORS は要らない）
- **API Gateway → Lambda**: API Gateway が発行の Lambda（`tickets`）を呼ぶ。画像は base64 で Lambda に渡るので、Lambda の 6MB の上限から画像の上限を 4MiB にしている
- **Lambda（`tickets`）**: 画像の大きさと形式を確かめ、解析サーバーに画像をそのまま送る。`PASS` ならコードと sig を作り、sig 付きの QR 画像の URL と一緒に返す。sig の salt とコードの固定文字列、解析サーバーの API キーは、起動時に Parameter Store から読む。salt は入れ替えられるように、今と前の 2 つを 1 つの JSON で持つ

  ```json
  { "current": "新しい salt", "previous": "前の salt（入れ替え中だけ）" }
  ```

- **発行の Lambda の置き場所**: VPC のプライベートサブネットに置き、外の解析サーバーには NAT ゲートウェイから出る。解析サーバーから見える送信元は NAT の固定の IP になる
- **画像の縮小**: 画面で画像を選んだとき、上限を超えていれば Compressor.js（ブラウザの canvas で縮めて JPEG にする）で縮める。上限以下の写真は加工せずに送る。利用者に縮めてもらったり、スクリーンショットで撮り直してもらったりしなくても、高画素の端末の写真を送れるようにするため
- **検証**: 画面は、`config.json` と API の応答を valibot で確かめる（形が違えば「予期しない応答」として扱う）。最終的な判定（大きさ・形式）は API が行う
- **古いブラウザへの対応**: 利用者に OS やブラウザの更新を求められないので、古いブラウザに合わせる。ビルドの出力を iOS 13（Safari 13）・Chrome 80 に合わせる（`build.target`。新しい構文を変換する）。CSS は Tailwind CSS 3.4。足りない組み込みの関数は core-js で補う（`Object.hasOwn`）。トップレベルの `await` と `AbortSignal.timeout` は使わない

## 1-5. QR 表示

### 1-5-1. 実装内容

#### API 実装

（`go/` から。入口・組み立て・エラーの変換はサービスチケット発行と同じファイル）

| No. | ファイル | 内容 |
|---|---|---|
| 1 | `cmd/ticketqr/main.go`・`wire.go` | Lambda の入口と組み立て（サービスチケット発行と同じ）。QR 画像は別の Lambda 関数 `get-qr` に同じプログラムを載せている |
| 2 | `internal/httpapi/route.go` | ルートキー `GET /v1/tickets/{ticketCode}/qr` → `GetQR` |
| 3 | `internal/httpapi/handler.go` | `GetQR`: `verified` でパスの `ticketCode` とクエリの `sig` を照合し、合えば `qr.PNG` の PNG を `200 image/png`（base64 で API Gateway に渡す）。合わなければ 403。共通のヘッダー（`Cache-Control: no-store` など）を付ける |
| 4 | `internal/httpapi/errors.go` | 403 `FORBIDDEN` の応答（JSON） |
| 5 | `internal/signer/signer.go` | sig の照合 `Verify`（今の salt と、入れ替え中は前の salt でも照合。比べるのは `hmac.Equal`） |
| 6 | `internal/qr/qr.go` | コードを QR の PNG にする `PNG`（`skip2/go-qrcode`、256×256px、誤り訂正レベル M、周りの余白あり） |

#### 画面表示実装

（`web/src/` から）

| No. | ファイル | 内容 |
|---|---|---|
| 1 | `modes/page/TicketPage.vue` | チケット画面。URL の `code`（パス）と `sig`（クエリ）を `TicketRouteSchema` で確かめ、合えば QR・使い方の説明文（`data-testid="ticket-usage"`）・ボタンを出す。形が違う、または QR の読み込みに失敗した（`qrFailed`）ときは「無効なチケット URL です」 |
| 2 | `modes/page/api.ts` | QR 画像 API の URL の組み立て `qrUrl`（`{apiBaseUrl}/v1/tickets/{code}/qr?sig={sig}`。コードと sig は URL エンコード）と、URL のパラメータの形 `TicketRouteSchema` |
| 3 | `components/TicketCard.vue` | QR の表示（`<img>`、256×256、`alt="チケットQRコード"`）。読み込みに失敗したら `qrError` を出す。コード文字列は画面に出さず、属性 `data-ticket-code` にだけ持つ |
| 4 | `components/AppBanner.vue` | 先頭のバナー（発行画面と同じ） |
| 5 | `components/ErrorMessage.vue` | 「無効なチケット URL です」の枠 |
| 6 | 「別の証明書の画像で発行する」（`TicketPage.vue` の `RouterLink`）・`stores/ticket.ts` | 押すと `store.reset()` で選んだ画像と状態を消して `/` へ。見た目は「発行する」ボタンと同じ（`data-testid="grant-again"`） |

### 1-5-2. 実装方式

- **URL だけから描く**: チケット画面は、URL のコードと sig を valibot で確かめ、`<img src="/v1/tickets/{コード}/qr?sig={sig}">` で QR を読み込む。発行の結果は画面に保存しない（再読み込みや共有に強く、再発行もされない）
- **sig で確かめる**: QR 画像 API は、この API が発行した QR 画像の URL（sig が合うもの）にだけ QR を返す。sig が合わない URL は 403 になり、画面は `<img>` の読み込みの失敗として「無効なチケット URL です」を出す（`<img>` からは 403 と通信の失敗を区別できないので、どちらも同じ文言）
- **別の Lambda 関数**: QR 画像は、発行とは別の Lambda 関数（`get-qr`。VPC の外）で返す。画像の表示が、発行（解析サーバーを呼ぶ）の同時実行数の上限で止まらないようにするため
- **表示の調整**: QR の画像には周りに白い余白があるので、見出しとの間・使い方の説明文との間の余白を小さくしている

## 2. 設計上の判断

| 論点 | 採用 | 不採用 |
|---|---|---|
| 発行した QR 画像の URL が正しいかを、後でどう確かめるか（記録を持つか） | QR 画像の URL に sig（HMAC）を付け、sig で確かめる。データベースを持たずに済み、API を増やしても状態を共有しなくてよい | 発行したチケットをデータベースに保存して照合する。データベースの構築・運用・費用が増え、QR の表示のたびに読みに行く |
| 発行と QR 画像を、同じ Lambda 関数で返すか | 分ける（`tickets` と `get-qr`。同じプログラム）。QR の表示を発行（解析サーバーを呼ぶ）の上限から切り離せ、VPC に入れるのは発行の関数だけで済む | 1 つの関数にまとめる。発行が混んで同時実行数の上限に達すると、QR の表示まで止まる。QR の関数も VPC に入る |
| 発行の Lambda から、解析サーバーにどうつなぐか | VPC のプライベートサブネットに置き、NAT ゲートウェイから出る。送信元が NAT の固定の IP になり、解析サーバー側で IP で許可できる | VPC の外に置く。送信元の IP が決まらず、解析サーバー側で許可できない |
| 画面と API を、どのアドレスで提供するか | すべて CloudFront で受け、`/v1/*` を API Gateway に振り分ける（統合）。画面と API が同じオリジンになり、CORS が要らず、CSP も単純になる | 画面（CloudFront）と API（API Gateway の URL）を別のオリジンにする（直接）。CORS と、CSP に API のオリジンが要る。テスト・開発用には残している |
| 画像の上限をいくつにするか | 4MiB。Lambda が受け取れるのは 6MB までで、API Gateway が画像を base64 にすると約 1.33 倍になるため | 6MB 前後にする。base64 にすると Lambda の上限を超え、API に届かない |
| 大きな写真をどう送るか（縮める対象） | 上限を超えた写真だけを縮める。高画素の端末の写真も、利用者が何もしなくても送れる。上限以下の写真は加工せずに送り、今の解析の結果を変えない | すべての写真を縮める。上限以下の写真まで画質が変わり、解析の結果が変わるおそれがある。縮めずにエラーにし、利用者に縮めてもらう（スクリーンショットなど）。利用者側の対応は期待できない |
| どこで縮めるか | 画面（ブラウザ）で、Compressor.js を使って縮める。利用者に縮めてもらう必要がない。API に届く前に大きさを抑えられる。ブラウザで縮める方法は canvas だけで、Compressor.js はその手間（写真の向き、大きくなったら元を返すなど）を引き受ける | API（Lambda）で縮める。上限を超えた画像はそもそも API に届かない。canvas を直接使う。写真の向きなどを自前で扱う手間が増える |
| 古いブラウザ（iOS 13）で、CSS をどう書くか | Tailwind CSS 3.4 | Tailwind CSS 4。iOS 15.3 以前でスタイルが付かない |
| 古いブラウザで、設定や応答の形をどう確かめるか | valibot | zod 4。読み込み時に `BigInt`（iOS 14 から）を使い、iOS 13 で画面が真っ白になる |
| 古いブラウザに、足りない組み込みの関数をどう補うか | core-js で、使う関数（`Object.hasOwn`）だけを補う。ビルドは構文しか変換しないため | 補わない（Pinia が使う `Object.hasOwn` で止まる）。core-js をまるごと入れる（大きくなる） |
| Android でカメラをどう使わせるか | 「画像を選ぶ」と「カメラを起動」の 2 つのボタンに分ける | 選択欄 1 つ。Android 14 以降は選択画面がフォトピッカーになり、カメラを選べない |
| エラーをどこに出すか | 「発行する」ボタンの下の 1 か所に、送る前の問題と API のエラーをそろえて出す。見落としを防ぐ | 画像の選択欄の近くと、ボタンの近くに分けて出す。どこに出たか分かりにくく、見落としやすい |
| チケット画面に何を出すか | QR だけを出し、コード文字列と発行日時は出さない。利用者に必要なのは QR だけ。コード文字列は QR とテスト用の属性にだけ持つ | コード文字列と発行日時も出す。利用者には使い道がなく、画面が混む |
| 発行の結果をどう見せるか（発行方式） | 画面遷移方式（チケット画面に移り、URL だけから QR を描く）。再読み込み・共有をしても同じ QR が出る。方式はビルドのときに選べる（`GRANT_MODE`。既定は `page`） | その場表示方式（発行画面の中に QR を出す）。再読み込みすると消える。フォーム送信方式（`fetch` を使わないフォーム）。送る前の確認・縮小・「カメラを起動」がなく、採用は例外 |
