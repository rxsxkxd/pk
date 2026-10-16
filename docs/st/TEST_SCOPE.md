# テスト観点の一覧（テスト仕様書の前提）

テスト仕様書を作るときの入力。[CHANGES.md](CHANGES.md) の事項と、CHANGES.md から外した事項（設定の話、枝葉）を並べ、事項ごとに、今あるテストと、足りない確かめ方を書く。テスト仕様書は、この一覧の事項をすべて含める（2026-10-14 時点の `go` ブランチ）。

## 1. 区分

| 順 | 区分 | 中身 | どこで動くか |
|---|---|---|---|
| 1 | 単体（Go） | `go/internal/**/*_test.go` | 手元・CI |
| 2 | 単体（web） | `web/test/**/*.test.ts` と、方式ごとの `web/src/modes/<方式>/<方式>.test.ts`（Vitest。画面は happy-dom でマウント） | 手元・CI |
| 3 | E2E | `e2e/tests/page-mode.spec.ts`（`compose.e2e.yaml`。Lambda RIE + apigw-local + Playwright の Chromium）。**CloudFront・S3・本物の API Gateway は使わず、画面と API は別オリジン（直接の構成）** | 手元（[E2E_RUN.md](E2E_RUN.md)） |
| 4 | スモーク | `deploy.yml` のデプロイ後の確認（`curl` で画面・`config.json`・発行・QR） | GitHub Actions（AWS 上で未実行） |
| 5 | AWS | 本物の AWS 環境でしか確かめられないもの。今は手順もテストもない（5章で検討） | AWS |
| 6 | 実機 | iPhone・Android の端末で手で確かめるもの | 端末 |

表の「specによるテスト」は自動のテスト（単体）。「spec以外の確認事項」は、手で確かめる・AWS 上で確かめる事項。実施日・結果・実施者・備考は、確かめたときに書く。

## 2. CHANGES.md の事項

### 2.1 チケット発行の画面操作

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | 発行画面の並び（バナー、見出し、説明文、画像の選択、ボタン、エラーの枠、補足事項）、画像を選ぶまで押せない | 単体（web: `banner`、`grant-description`、`grant-notes`、`page` の "disabled until a usable photo"） | 実機（見た目） |  |  |  |  |
| 2 | iOS は選択欄 1 つ、Android は 2 つのボタン（縦並び）、ファイル名と大きさ | 単体（web: `page` の non-Android / Android、`platform`） | 実機（iOS のメニュー、Android 14 以降のカメラ、縦並びの見た目） |  |  |  |  |
| 3 | 4MB 超の縮小（縮小中は押せない、結果の表示、縮められないときの文言） | 単体（web: `shrink`、`store` の shrinking、`page` の "shrunk"） | 実機（処理時間、写真の向き、HEIC、高画素の JPEG のメモリ） |  |  |  |  |
| 4 | 対応していない形式の文言、押せない | 単体（web: `store` の checkFile・errorMessage） | 実機 |  |  |  |  |
| 5 | 送信中の表示、二重発行の防止 | 単体（web: `store` の "second click"） | 実機 |  |  |  |  |
| 6 | 発行後に QR画面へ（履歴の置き換え） | 単体（web: `page` の "replace"） | 実機 |  |  |  |  |
| 7 | 失敗の文言をボタンの下に、もう一度押せる、別の画像で消える | 単体（web: `store` の errorMessage・sending） | 実機 |  |  |  |  |

### 2.2 エラーの文言

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | 画像の大きさ超過 のエラー文言 「画像のサイズが大きすぎます」 | 単体（web: `store` の "message for"） | 実機 |  |  |  |  |
| 2 | 画像の非対応形式 のエラー文言 「この形式の画像には対応していません（JPEG / PNG / HEIC / HEIF / AVIF / WebP）」 | 単体（web: `store` の "message for"） | 実機 |  |  |  |  |
| 3 | API のエラーコード REJECT / RETRY のエラー文言 「判定ができませんでした。再度お試しください」 | 単体（web: `store` の "message for"） | 実機 |  |  |  |  |
| 4 | API のエラーコード 混み合い / そのほか のエラー文言 「画像の送付に失敗しました。少し待ってから再度お試しください」 | 単体（web: `store` の "message for"） | 実機 |  |  |  |  |
| 5 | 30 秒のタイムアウト、通信の失敗 「画像の送付に失敗しました。少し待ってから再度お試しください」 | 単体（web: `api`） | 実機 |  |  |  |  |

### 2.3 チケット付与 API

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | `POST /v1/tickets` → 201 `{ ticketCode, issuedAt, sig, qrUrl }`: 判定が通る画像を送ると発行され、コード・発行日時・sig・QR 画像の URL が JSON で返ること | 単体（Go: `TestGrantAcceptJSON`） | スモーク（curl）・AWS（CloudFront 経由） |  |  |  |  |
| 2 | エラー 413 / 415 / 422 / 502 / 504 の JSON: 発行できないとき（大きすぎる・形式が違う・判定が REJECT / RETRY・解析サーバーの失敗・時間切れ）に、理由ごとのステータスとエラーコードが JSON で返ること（画面はこのコードで文言を選ぶ） | 単体（Go: `TestGrantInlineErrors`、`TestGrantInlineWithHTTPAnalyzer`） | スモーク（curl）・AWS（約 4.5MB 超で Lambda に届かないときの API Gateway の応答） |  |  |  |  |
| 3 | 画像の形式の判別、4MiB の上限 | 単体（Go: `imageinput`、`TestMaxImageBytes`、`TestUploadFormats`） | スモーク（curl）・AWS（CloudFront 経由） |  |  |  |  |
| 4 | チケットコードの形（日本時間、UUIDv4、固定文字列） | 単体（Go: `code_test`） | 実機 |  |  |  |  |
| 5 | sig（HMAC、salt の入れ替え中は新旧） | 単体（Go: `signer_test`） | AWS（Parameter Store の salt を入れ替える手順） |  |  |  |  |
| 6 | 解析サーバーへの送信（そのまま送る、5 秒、1 回のやり直し、応答のログ） | 単体（Go: `analyzer/http_test`） | AWS（本物の解析サーバー。接続先は未決） |  |  |  |  |
| 7 | ブラウザと OS の情報のログ | 単体（Go: `TestClientLog`） | AWS（CloudWatch） |  |  |  |  |
| 8 | `Cache-Control: no-store`: API のすべての応答（発行の 201 とエラー、QR 画像の 200 と 403）に、応答のヘッダー `Cache-Control: no-store` と `X-Content-Type-Options: nosniff` が付いていること。ブラウザや途中のキャッシュに、発行の結果や QR 画像が保存されない | 単体（Go: 発行の JSON の 201・エラー、QR の 200・403） | スモーク（curl）・ブラウザのデベロッパーツール |  |  |  |  |

### 2.4 QR 表示

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | チケット画面の並び（バナー、見出し、QR、使い方、ボタン）、コード・日時を出さない | 単体（web: `page` の ticket screen、`banner`） | 実機（見た目・QR の表示） |  |  |  |  |
| 2 | 再読み込み・後で開く（再発行しない）: チケット画面（`#/tickets/{コード}?sig={sig}`）で再読み込みしても、その URL を保存して後で開いても、同じ QR が出る。このとき発行の API（`POST /v1/tickets`）は呼ばれず、新しいチケットは発行されない（呼ばれるのは QR 画像 API の `GET …/qr` だけ） | 単体（web: API を呼ばないこと） | 実機・AWS（CloudWatch） |  |  |  |  |
| 3 | URL の形違い・sig違いで「無効なチケット URL です」（使い方は出さない） | 単体（web: `page` の missing / malformed、QR の読み込み失敗） | 実機 |  |  |  |  |
| 4 | 「別の証明書の画像で発行する」で画像を消して発行画面へ | 単体（web: `page`。画像が消えることも確かめる） | 実機 |  |  |  |  |
| 5 | `GET /v1/tickets/{コード}/qr?sig=` → 200 PNG、sig違いは 403: 発行で返った `qrUrl`（チケット画面が読み込む QR の URL）を開くと、200 で `Content-Type: image/png` の QR 画像（256×256px）が返る。`sig` を 1 文字変える・`sig` を消す・コードを別のものに変えると、403 で本文は JSON の `{"error":{"code":"FORBIDDEN",…}}`。どちらの応答にも `Cache-Control: no-store` | 単体（Go: `TestPatternBFlow`、`TestSignatureRequired`、`qr_test`） | ブラウザのデベロッパーツール |  |  |  |  |

### 2.5 実装方式・構成

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|
| 1 | 画面と API が同じオリジン（CloudFront の `/v1/*` を API Gateway へ） | なし | ブラウザのデベロッパーツール（統合の構成で `$WEB_URL/v1/tickets`）、AWS |  |  |  |  |
| 2 | ルートの振り分け（発行・QR）: 要求のメソッドとパスに応じて、正しい処理に届くこと。`POST /v1/tickets`（画像を送る）は発行の関数（`tickets`）に届いて 201 の JSON が返る。`GET /v1/tickets/{コード}/qr?sig={sig}` は QR の関数（`get-qr`）に届いて 200 の PNG が返る。定義のないパス（例: `GET /v1/unknown`）は 404 | 単体（Go: `route_test`） | ブラウザのデベロッパーツール（ネットワークのタブで、発行と QR の要求の行き先と応答）・実機 |  |  |  |  |
| 3 | QR を別の関数（`get-qr`、VPC の外）で返す | なし | AWS（関数の設定。発行が止まっても QR が出ること） |  |  |  |  |
| 4 | 発行の関数を VPC のプライベートサブネットに置き、NAT で解析サーバーへ | なし | AWS（関数の VPC の設定、外への通信） |  |  |  |  |
| 5 | Parameter Store の値を起動時に読む | 単体（Go: `config_test`。Parameter Store を使わず環境変数で渡す場合だけ） | AWS（本物の Parameter Store、権限） |  |  |  |  |
| 6 | `config.json` の検証。valibot で検証可能な形式であること | 単体（web: `config`） | ブラウザ（配置された `config.json`） |  |  |  |  |
| 7 | CSP（`img-src` の `blob:` など）: 画面（`index.html`）の応答に、CloudFront が `Content-Security-Policy` を付けていて、`web.yaml` の方針どおりであること（`default-src 'self'`、`img-src 'self' data: blob:`、`connect-src 'self'`、`frame-ancestors 'none'` など）。`blob:` は、上限を超えた写真を縮めるときに、Compressor.js が写真を `blob:` の URL で読むために要る。4MB を超える写真を選ぶと「縮小しました」が出て発行でき、ブラウザのコンソールに CSP の違反が出ない | なし | AWS（CloudFront の応答のヘッダー、縮小が CSP で止まらないこと） |  |  |  |  |

## 3. CHANGES.md から外した事項

| 順 | 事項 | 仕様の参照先 | 今のテスト | 足りない確かめ方 | 実施日 | 結果 | 実施者 | 備考 |
|---|---|---|---|---|---|---|---|---|
| 1 | 画面を S3 から配信（CloudFront 経由のみ、`index.html`・`config.json` は `no-cache`、ほかは長期キャッシュ） | `infra/cloudformation/web.yaml`、web/DEPLOY.md | なし | スモーク（画面が開く）、AWS（ヘッダー、S3 を直接開けないこと） |  |  |  |  |
| 2 | CloudFront の振り分けの細部（`/v1/*` はキャッシュしない、エラーの置き換えをしない） | `web.yaml`、web/DEPLOY.md | なし | AWS |  |  |  |  |
| 3 | API Gateway の 1 秒あたりの上限（50 / 一時的に 100） | `infra/cloudformation/api.yaml`、infra/RATE_LIMITING.md | なし | AWS（設定値の確認。負荷をかける確認は任意） |  |  |  |  |
| 4 | 発行の上限（1時間 10,000 / 1日 100,000）。超えたら発行の 2 ルートが 429、QR は止めない、戻ったら 50 / 100 に戻す、10 分ごとの見直し | `infra/cloudformation/quota-guard.yaml`、infra/RATE_LIMITING.md 7章 | なし（cfn-lint だけ） | AWS（5.3）。時間の枠の区切り方は実際の時間をかけないと見られない |  |  |  |  |
| 5 | WAF | infra/API_PROTECTION.md、web/DEPLOY.md 13章 | なし | 判断の後 |  |  |  |  |

## 4. この一覧を作るときに足したテスト

- Go: 発行の JSON（201・エラー）と QR（200・403）でも `Cache-Control: no-store` などの共通のヘッダーを確かめる（`go/internal/httpapi/handler_test.go`）
- web: 「別の証明書の画像で発行する」を押すと、選んだ画像が消えることを確かめる（`web/src/modes/page/page.test.ts`）

ほかの足りない事項は、AWS 上か実機でしか確かめられない。

## 5. 本物の AWS 環境に対するテスト（検討）

開発計画は [aws-test/PLAN.md](aws-test/PLAN.md)。今の E2E とは別に、デプロイ済みの AWS 環境に向けたテストは書ける。手元（この環境）では、AWS の認証情報と試験用の環境がないので流せない。書くだけなら書けるが、一度も流していないテストになる。

### 5.1 形

- 置き場所: `aws-test/`（E2E とは別。E2E は compose の中で完結し、こちらは外の URL に向ける）
- 道具: Playwright（E2E と同じ。画面の操作と、`request` での API の呼び出しの両方ができる）。AWS の設定を読む部分は AWS SDK（JavaScript）
- 向ける先: 環境変数で渡す（`WEB_URL`、`API_URL`、スタック名）。値は CloudFormation の出力から取る
- 流す場所: `deploy.yml` のスモークの後（GitHub Actions の OIDC のロールをそのまま使う）か、認証情報のある手元の端末

### 5.2 段階

| 順 | 段階 | 確かめること | 必要なもの | 環境への影響 |
|---|---|---|---|---|
| 1 | A. 外から見える挙動 | 画面が開く（S3）、キャッシュの指定、配置した `config.json`、CloudFront が付けるヘッダー（CSP）、`/v1/*` の振り分け、`/v1/*` をキャッシュしない、API のエラーを置き換えない、画像の大きさの境界、縮小が CSP で止まらない | URL だけ（認証情報は要らない） | 発行が数回（チケットは保存しないので後片付けは要らない。上限の数には入る） |
| 2 | B. 構成の確認（読むだけ） | 発行の関数が VPC のプライベートサブネット、`get-qr` は VPC の外、ルートの上限が 50 / 100、上限のアラームの値と動作先、S3 のパブリックアクセスのブロック | 読み取りの権限（`lambda:GetFunctionConfiguration`、`apigateway:GET`、`cloudwatch:DescribeAlarms` など） | なし |
| 3 | C. 状態を変える確認 | 上限の動き: `aws cloudwatch set-alarm-state` でアラームを ALARM にする → ガードの関数が動く → 発行が 429、QR は 200 → OK に戻す → 発行が 201 に戻る。1 秒あたりの上限を超えると 429 になること（任意） | 試験用の環境と、アラームの状態を変える権限 | 試験中は発行が止まる。**本番では流さない** |

### 5.3 前提と限り

- 試験用の環境を AWS に一つ持つ（本番と同じテンプレート）。解析サーバーは `AnalyzerMode=mock` か、`analyzer-stub/` のスタブ（`analyzer-stub/cdk`）にする。本物の解析サーバーにつなぐ確認は、接続先が決まってから
- 1時間・1日の枠の区切り方（1日が日本時間 9 時で区切られるか）は、アラームの状態を手で変える方法では見られない。実際に件数を数えるには時間がかかるので、手動の確認として残す
- 単体テスト・API のテスト・E2E で確かめられること（応答の形、エラーコード、署名、画面の操作と文言）は含めない。AWS の構成が関わるところだけを確かめる
- 実機（iOS 13 / Android 9）は AWS のテストでは確かめられない。クラウドの実機サービスを使うかは別に決める

### 5.4 進め方の案

1. A と B を書き、`deploy.yml` のスモークの代わりに流す（読むだけなので、デプロイのたびに流せる）
2. C は手動で起動するワークフロー（`workflow_dispatch`）にし、試験用の環境だけで流す
3. 試験用の環境ができるまでは、書いても流せない。先に環境を用意するかを決める

## 6. 保留しているテスト

2章のテスト項目から外し、実施を保留しているもの（2026-10-15）。テスト仕様書・TEST_RESULT.md の対象には含めない。再開するときは、2章の表に戻す。

| 順 | 確認事項と期待結果 | specによるテスト | spec以外の確認事項 | 保留にした日 | 備考 |
|---|---|---|---|---|---|
| 1 | 古いブラウザへの対応（ビルドの出力先、core-js、valibot、Tailwind 3.4）: iOS 13 の Safari と Android 9 の Chrome（80）で、画面が表示され（真っ白にならない）、スタイルが付き、画像を選んで発行し、チケット画面に QR が出る | 単体（web: `main-imports`）、ビルド | 実機（iOS 13 / Android 9） | 2026-10-15 | 元は 2.5 の 7。対応の中身は web/DESIGN.md 2.4。実機で確かめていないことは README の未対応事項「古い端末での動作」にも書いてある |
