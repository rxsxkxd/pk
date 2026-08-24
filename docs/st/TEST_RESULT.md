# 3. テスト項目

### 3.1 チケット発行の画面操作

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | 発行画面の並び（バナー、見出し、説明文、画像の選択、ボタン、エラーの枠、補足確認事項と期待結果）、画像を選ぶまで押せない | 単体（web: `banner`、`grant-description`、`grant-notes`、`page` の "disabled until a usable photo"） | 実機（見た目） | 2026/10/15 | OK | SK | iOSのみ |
| 2 | iOS は選択欄 1 つ、Android は 2 つのボタン（縦並び）、ファイル名と大きさ | 単体（web: `page` の non-Android / Android、`platform`） | 実機（iOS のメニュー、Android 14 以降のカメラ、縦並びの見た目） | 2026/10/15 | OK | SK  | iOSのみ |
| 3 | 4MB 超の縮小（縮小中は押せない、結果の表示、縮められないときの文言） | 単体（web: `shrink`、`store` の shrinking、`page` の "shrunk"） | 実機（処理時間、写真の向き、HEIC、高画素の JPEG のメモリ） |  |   |   |  |
| 4 | 対応していない形式の文言、押せない | 単体（web: `store` の checkFile・errorMessage） | 実機 | 2026/10/15 | OK  | SK  | iOSのみ |
| 5 | 送信中の表示、二重発行の防止 | 単体（web: `store` の "second click"） | 実機 | 2026/10/15 | OK  | SK  | iOSのみ  |
| 6 | 発行後に QR画面へ（履歴の置き換え） | 単体（web: `page` の "replace"） | 実機 | 2026/10/15 | OK  | SK  | iOSのみ |
| 7 | 失敗の文言をボタンの下に、もう一度押せる、別の画像で消える | 単体（web: `store` の errorMessage・sending） | 実機 | 2026/10/15 | OK  | SK  | iOSのみ |

### 3.2 エラーの文言

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | 画像の大きさ超過 のエラー文言 「画像のサイズが大きすぎます」| 単体（web: `store` の "message for"） | 実機 |  |  |  |  |
| 2 | 画像の非対応形式 のエラー文言  「この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）」| 単体（web: `store` の "message for"） | 実機 | 2026/10/15 | OK | SK |  |
| 3 | API のエラーコード REJECT / RETRYのエラー文言  「判定ができませんでした。再度お試しください」 | 単体（web: `store` の "message for"） | 実機 | 2026/10/15 | OK | SK |  |
| 4 | API のエラーコード 混み合い / そのほか のエラー文言  「画像の送付に失敗しました。少し待ってから再度お試しください」| 単体（web: `store` の "message for"） | 実機 | 2026/10/15 | OK | SK |  |
| 5 | 30 秒のタイムアウト、通信の失敗 「画像の送付に失敗しました。少し待ってから再度お試しください」 | 単体（web: `api`） | 実機 |  |  |  |  |

### 3.3 チケット付与 API

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | `POST /v1/tickets` → 201 `{ ticketCode, issuedAt, sig, qrUrl }`: 判定が通る画像を送ると発行され、コード・発行日時・sig・QR 画像の URL が JSON で返ること | 単体（Go: `TestGrantAcceptJSON`） | スモーク（curl）・AWS（CloudFront 経由） | 2026/10/15 | OK | SK |  |
| 2 | エラー 413 / 415 / 422 / 502 / 504 の JSON: 発行できないとき（大きすぎる・形式が違う・判定が REJECT / RETRY・解析サーバーの失敗・時間切れ）に、理由ごとのステータスとエラーコードが JSON で返ること（画面はこのコードで文言を選ぶ） | 単体（Go: `TestGrantInlineErrors`、`TestGrantInlineWithHTTPAnalyzer`） | スモーク（curl）・AWS（約 4.5MB 超で Lambda に届かないときの API Gateway の応答） |  |  |  |  |
| 3 | 画像の形式の判別、4MiB の上限 | 単体（Go: `imageinput`、`TestMaxImageBytes`、`TestUploadFormats`） | スモーク（curl）・AWS（CloudFront 経由） |  |  |  |  |
| 4 | チケットコードの形（日本時間、UUIDv4、固定文字列） | 単体（Go: `code_test`） | 実機 | 2026/10/15 | OK | SK |  |
| 5 | sig（HMAC、salt の入れ替え中は新旧） | 単体（Go: `signer_test`） | AWS（Parameter Store の salt を入れ替える手順） | 2026/10/15 | OK | SK |  |
| 6 | 解析サーバーへの送信（そのまま送る、5 秒、1 回のやり直し、応答のログ） | 単体（Go: `analyzer/http_test`） | AWS（本物の解析サーバー。接続先は未決） | 2026/10/15 | OK | SK |  |
| 7 | ブラウザと OS の情報のログ | 単体（Go: `TestClientLog`） | AWS（CloudWatch） |  |  |  |  |
| 8 | `Cache-Control: no-store`: API のすべての応答（発行の 201 とエラー、QR 画像の 200 と 403）に、応答のヘッダー `Cache-Control: no-store` と `X-Content-Type-Options: nosniff` が付いていること。ブラウザや途中のキャッシュに、発行の結果や QR 画像が保存されない | 単体（Go: 発行の JSON の 201・エラー、QR の 200・403） | スモーク（curl）・ブラウザのデベロッパーツール |  |  |  |  |
| 9 | 解析サーバーのタイムアウト: 解析サーバーの応答が遅いとき、1 回 5 秒で打ち切り、1 回だけやり直し、約 10 秒で 504 `ANALYSIS_TIMEOUT` の JSON が返ること。5 秒以内に応答があれば発行されること | 単体（Go: `analyzer/http_test` の時間切れとやり直し） | AWS（検証環境。応答の遅いダミーの解析サーバー。PROD_VERIFICATION.md 5章） |  |  |  |  |

### 3.4 QR 表示

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | チケット画面の並び（バナー、見出し、QR、使い方、ボタン）、コード・日時を出さない | 単体（web: `page` の ticket screen、`banner`） | 実機（見た目  ・QR の表示） | 2026/10/15  | OK | SK |  |
| 2 | 再読み込み・後で開く（再発行しない）: チケット画面（`#/tickets/{コード}?sig={sig}`）で再読み込みしても、その URL を保存して後で開いても、同じ QR が出る。このとき発行の API（`POST /v1/tickets`）は呼ばれず、新しいチケットは発行されない（呼ばれるのは QR 画像 API の `GET …/qr` だけ） | 単体（web: API を呼ばないこと） | 実機・AWS(CloudWatch) |  |  |  |  |
| 3 | URL の形違い・sig違いで「無効なチケット URL です」（使い方は出さない） | 単体（web: `page` の missing / malformed、QR の読み込み失敗） | 実機 | 2026/10/15  | OK |SK  |  |
| 4 | `GET /v1/tickets/{コード}/qr?sig=` → 200 PNG、sig違いは 403: 発行で返った `qrUrl`（チケット画面が読み込む QR の URL）を開くと、200 で `Content-Type: image/png` の QR 画像（256×256px）が返る。`sig` を 1 文字変える・`sig` を消す・コードを別のものに変えると、403 で本文は JSON の `{"error":{"code":"FORBIDDEN",…}}`。どちらの応答にも `Cache-Control: no-store` | 単体（Go: `TestPatternBFlow`、`TestSignatureRequired`、`qr_test`） | ブラウザのデベロッパーツール |  |  |  |  |


### 3.5 実装方式・構成

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | 画面と API が同じオリジン（CloudFront の `/v1/*` を API Gateway へ） | なし | ブラウザのデベロッパーツール（統合の構成で `$WEB_URL/v1/tickets`）、AWS | 2026/10/15 | OK | SK |  |
| 2 | ルートの振り分け（発行・QR）: 要求のメソッドとパスに応じて、正しい処理に届くこと。`POST /v1/tickets`（画像を送る）は発行の関数（`tickets`）に届いて 201 の JSON が返る。`GET /v1/tickets/{コード}/qr?sig={sig}` は QR の関数（`get-qr`）に届いて 200 の PNG が返る。定義のないパス（例: `GET /v1/unknown`）は 404 | 単体（Go: `route_test`） | ブラウザのデベロッパーツール（ネットワークのタブで、発行と QR の要求の行き先と応答）・実機 |  |  |  |  |
| 3 | QR を別の関数（`get-qr`、VPC の外）で返す | なし | AWS（関数の設定。発行が止まっても QR が出ること） | 2026/10/15 | OK | SK |  |
| 4 | 発行の関数を VPC のプライベートサブネットに置き、NAT で解析サーバーへ | なし | AWS（関数の VPC の設定、外への通信） | 2026/10/15 | OK | SK |  |
| 5 | Parameter Store の値を起動時に読む | 単体（Go: `config_test`。Parameter Store を使わず環境変数で渡す場合だけ） | AWS（本物の Parameter Store、権限） | 2026/10/15 | OK | SK |  |
| 6 | `config.json` の検&#35388;。valibotで検&#35388;可能な形式であること | 単体（web: `config`） | ブラウザ（配置された `config.json`） | 2026/10/15 | OK  | SK |  |
| 7 | CSP（`img-src` の `blob:` など）: 画面（`index.html`）の応答に、CloudFront が `Content-Security-Policy` を付けていて、`web.yaml` の方針どおりであること（`default-src 'self'`、`img-src 'self' data: blob:`、`connect-src 'self'`、`frame-ancestors 'none'` など）。`blob:` は、上限を超えた写真を縮めるときに、Compressor.js が写真を `blob:` の URL で読むために要る。4MB を超える写真を選ぶと「縮小しました」が出て発行でき、ブラウザのコンソールに CSP の違反が出ない | なし | AWS（CloudFront の応答のヘッダー、縮小が CSP で止まらないこと） |  |  |  |  |
