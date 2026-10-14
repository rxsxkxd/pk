# AWS 環境に対するテスト 開発計画

デプロイ済みの AWS 環境に向けて流すテストの開発計画。今の E2E（`compose.e2e.yaml`。手元で完結し、CloudFront・S3・本物の API Gateway を使わない）とは別にする。確かめる事項の一覧は [TEST_SCOPE.md](../TEST_SCOPE.md)（5章が検討の結果）。

**状態**: 計画だけ。コードはまだない。試験用の AWS 環境と認証情報がないので、書いても流せない（2026-10-14）。

## 1. 目的

- AWS 上でしか確かめられない事項（TEST_SCOPE.md の「AWS」「スモーク」）をテストにする
- デプロイのたびに、構成が仕様どおりかを確かめられるようにする（`deploy.yml` の `curl` のスモークの置き換え）
- 発行の上限（quota-guard）が、実際に発行を止めて戻すことを確かめる

含めないこと:

- 単体テスト（Go・web）、API のテスト、E2E で確かめられること。API の応答の形やエラーコード、署名の照合、画面の操作と文言などは、そちらで確かめている（TEST_SCOPE.md 2章）。ここでは、AWS の構成（CloudFront、S3、API Gateway、Lambda の置き場所、上限）が関わるところだけを確かめる
- 実機（iOS 13 / Android 9）、本物の解析サーバーの判定、WAF（判断の後に足す）

## 2. 段階

| 段階 | 中身 | 必要な権限 | 環境への影響 | 流す時 |
|---|---|---|---|---|
| A. 外から見える挙動 | URL に向けて HTTP とブラウザで確かめる | なし（URL だけ） | 発行が数回（上限の数に入る） | デプロイのたび |
| B. 構成の確認 | AWS の設定を読んで確かめる | 読み取りだけ | なし | デプロイのたび |
| C. 状態を変える確認 | 上限のアラームを手で切り替えて、発行が止まって戻ることを確かめる | アラームの状態の変更 | 試験の間は発行が止まる | 手で起動。**試験用の環境だけ** |

## 3. 確かめる事項

### 3.1 A. 外から見える挙動

| ID | 事項 | 確かめ方 |
|---|---|---|
| A-1 | 画面が CloudFront から開く（S3） | `GET {WEB_URL}/` が 200、`text/html` |
| A-2 | キャッシュの指定（アップロードのときの指定） | `index.html`・`config.json` は `no-cache`、`assets/` は長期（`immutable`） |
| A-3 | 配置した `config.json` | 統合の構成では `apiBaseUrl` が `""` |
| A-4 | 応答のヘッダー（CloudFront が付ける） | CSP（`img-src` に `blob:`、`connect-src 'self'`、`frame-ancestors 'none'`）など、`web.yaml` のヘッダーの方針どおり |
| A-5 | `/v1/*` が API に届く | `POST {WEB_URL}/v1/tickets` が 201、その `qrUrl` が 200（発行と QR の両方の関数に届く）。応答の中身は単体・E2E で確かめているので、ここでは見ない |
| A-6 | `qrUrl` が同じオリジン（公開 URL の設定） | `qrUrl` が `{WEB_URL}/v1/...` で始まる |
| A-7 | `/v1/*` をキャッシュしない | 同じ QR の URL を 2 回取り、CloudFront のキャッシュに当たらない（`x-cache` が `Miss` か、キャッシュしない指定） |
| A-8 | API のエラーを CloudFront が置き換えない | 形式違い（テキストの添付）が、API の 415 の JSON のまま届く |
| A-9 | 画像の大きさの境界（API Gateway・Lambda の上限） | 4MiB + 1 バイトは Lambda まで届いて 413 `PAYLOAD_TOO_LARGE`。約 4.5MB 超（base64 で 6MB 超）・10MB 超は、ステータスと本文を記録する。期待値は初回の結果を見て決める（README の未対応事項） |
| A-10 | 上限を超えた写真の縮小が CSP で止まらない | ブラウザで `{WEB_URL}` を開き、4MB を超える JPEG を選んで「縮小しました」が出て発行できる（CSP は CloudFront にしかない） |

### 3.2 B. 構成の確認

| ID | 事項 | 確かめ方 |
|---|---|---|
| B-1 | 発行の関数が VPC の中 | `ticketqr-go-tickets` の `VpcConfig` にサブネットがあり、どれもプライベート（ルートテーブルの既定の経路が NAT） |
| B-2 | QR の関数が VPC の外 | `ticketqr-go-get-qr` の `VpcConfig` が空 |
| B-3 | 関数の基本の設定 | どちらも arm64。Parameter Store の名前が環境変数にある |
| B-4 | ルートの 1 秒あたりの上限 | ステージの設定が 50 / 100（発行の 2 ルート。上限に達していないとき） |
| B-5 | 発行の上限のアラーム | `ticketqr-quota-go-hourly`・`-daily` の値が 10,000 / 100,000、期間が 3600 / 86400、動作先がガードの関数、状態が OK |
| B-6 | ガードの見直しの予定 | EventBridge のルールが 10 分ごとで有効 |
| B-7 | S3 を直接開けない | バケットのパブリックアクセスのブロックがすべて有効。バケットの URL を直接開くと 403 |
| B-8 | CloudFront の振り分け | ディストリビューションの `/v1/*` の振る舞いが API のオリジン、キャッシュしない指定 |

### 3.3 C. 状態を変える確認

| ID | 事項 | 確かめ方 |
|---|---|---|
| C-1 | 上限に達すると発行が止まる | `aws cloudwatch set-alarm-state` で hourly を ALARM にする → ガードの関数が動く（ログ）→ `POST /v1/tickets` が 429 になるまで待つ（最大 1〜2 分） |
| C-2 | 止まっている間も QR は出る | 発行済みの `qrUrl` が 200 |
| C-3 | 戻る | hourly を OK にする → 発行が 201 に戻り、ルートの上限が 50 / 100 |
| C-4 | daily でも同じ | C-1〜C-3 を daily で |
| C-5 | 片方が ALARM の間は止まったまま | 両方を ALARM → 片方だけ OK → まだ 429 → 両方 OK で戻る |
| C-6 | 見直しの予定で戻る | ルートの上限を手で 0 にする（アラームは OK のまま）→ 10 分以内に 50 / 100 に戻る |
| C-7 | 1 秒あたりの上限（任意） | 短い時間に 100 件を超えて送り、429 が混ざる。発行の数が増えるので、流すかは決める |

注意: `set-alarm-state` で変えた状態は、次の評価（期間ごと）で実際の値に戻る。試験は評価の間に終える。終わったら必ず両方を OK に戻し、ルートの上限が 50 / 100 であることを確かめる（後片付けは、失敗したときも動かす）。

## 4. 作り

### 4.1 置き場所と道具

```
aws-test/
  PLAN.md            この計画
  package.json       @playwright/test（E2E と同じ版）、@aws-sdk/client-*（B・C）
  playwright.config.ts
  env.ts             環境変数の読み込みと、スタックの出力からの値の取り出し
  tests/
    a-public.spec.ts     A（HTTP）
    a-browser.spec.ts    A（画面。A-10 だけ）
    b-config.spec.ts     B
    c-quota.spec.ts      C（既定では流さない）
  fixtures/          画像（testdata/images を使い、大きい画像は試験の中で作る）
```

- Playwright を使う理由: 画面の操作（A-10）と HTTP の確認（`request`）を同じ道具で書け、E2E と書き方がそろう
- AWS の設定は AWS SDK for JavaScript v3 で読む（`lambda`、`apigatewayv2`、`cloudwatch`、`cloudformation`、`cloudfront`、`s3`、`ec2`、`events`）

### 4.2 設定

| 環境変数 | 中身 | 既定 |
|---|---|---|
| `IMPL` | `go` / `node` | `go` |
| `AWS_REGION` | リージョン | なし（必須） |
| `WEB_URL` | 画面の URL | `ticketqr-web-{IMPL}` の出力 `WebUrl` |
| `API_URL` | API Gateway の URL（B と、直接の構成の確認に使う） | `ticketqr-{IMPL}` の出力 `ApiUrl` |
| `AWS_TEST_ALLOW_QUOTA` | `1` のときだけ C を流す | なし |

- A は `WEB_URL` だけで流せるようにする（認証情報がなくても流せる）
- 本番で C を流さないため、C はスタックのタグ（例: `env=test`）も確かめ、合わなければ流さない

### 4.3 流す場所

- **デプロイの後**: `deploy.yml` のスモークの代わりに A と B を流す。デプロイのロール（OIDC）に、B の読み取りの権限を足す
- **手で起動**: C は `workflow_dispatch` の別のワークフローにし、試験用の環境のロールだけで流す
- **手元**: 認証情報のある端末で `npm test`（環境変数で向ける先を渡す）

### 4.4 権限

| 段階 | 権限 |
|---|---|
| A | なし |
| B | `cloudformation:DescribeStacks`、`lambda:GetFunctionConfiguration`、`apigateway:GET`、`cloudwatch:DescribeAlarms`、`events:DescribeRule`、`cloudfront:GetDistributionConfig`、`s3:GetBucketPublicAccessBlock`、`ec2:DescribeSubnets`、`ec2:DescribeRouteTables` |
| C | B に加えて `cloudwatch:SetAlarmState`、`apigateway:PATCH`（C-6 と後片付け）、`logs:FilterLogEvents`（ガードのログ） |

## 5. 前提

- 試験用の AWS 環境を一つ持つ（本番と同じテンプレート: `api.yaml`、`web.yaml`（統合の構成）、`quota-guard.yaml`、ネットワーク）
- 解析サーバーは `AnalyzerMode=mock`、または `analyzer-stub/` のスタブ（`analyzer-stub/cdk`）。B-1 の外への通信まで確かめるなら、VPC の外に置いたスタブに NAT 経由でつなぐ
- 本物の解析サーバーにつなぐ確認は、接続先が決まってから（README の「決めること」）

## 6. 進め方

| 順 | 作業 | 終わりの条件 |
|---|---|---|
| 1 | 試験用の環境を用意するかを決める（アカウント、費用、誰が流すか） | 決まる |
| 2 | 試験用の環境に、`deploy.yml`（統合の構成）でデプロイする | スモークが通る |
| 3 | 雛形（`package.json`、`playwright.config.ts`、`env.ts`）と A の HTTP の確認（A-1〜A-8） | 手元から通る |
| 4 | A-9 を流して、Lambda に届かない大きさのときの応答を記録し、期待値を決める（画面の文言を変えるなら、web の単体テストで確かめる） | 決まった期待値でテストが通る |
| 5 | A の画面の確認（A-10） | 通る |
| 6 | B | 通る。わざと設定を変えたスタックで落ちることも一度確かめる |
| 7 | `deploy.yml` のスモークを A・B に置き換える | デプロイのワークフローで通る |
| 8 | C と、その後片付け。手で起動するワークフロー | 試験用の環境で通る。途中で止めても上限が元に戻る |
| 9 | 結果を TEST_SCOPE.md・README に反映する（「AWS 上で未確認」の行を減らす） | 反映済み |

## 7. 決めること

- 試験用の環境を持つか（持たないなら、A だけを本番のデプロイの後に流す。C は流さない）
- C-7（1 秒あたりの上限に負荷をかける）を流すか
- A-9 の期待値（API Gateway の応答を見てから）
- WAF を入れたら、その確認（ルールで止まること）を足す
