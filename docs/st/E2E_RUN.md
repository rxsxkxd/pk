# E2E の手動実行手順

ローカルの Docker Compose で E2E（3つのコンテナ: `storage`・`api`・`e2e`）を手で流すための手順。構成と設計の理由は [E2E.md](E2E.md)、CI・CD での扱いは [E2E.md](E2E.md) の該当の章を参照。

## 1. 前提

| 項目 | 内容 |
|---|---|
| Docker | Docker Compose v2（`docker compose` のサブコマンド）が使えること。初回はイメージのビルドに数分かかる（golang、node、Lambda、Playwright のイメージを取得するため） |
| Node.js | 24 以上（SPA のビルドに使う） |
| SPA のビルド | `web/dist` を compose の前に作っておく。**SPA のソースを変えたら必ず作り直す**（古い `dist` のままだと、`data-testid` などがテストと合わずに失敗する） |

## 2. 手順

### 2.1 SPA をビルドする

```sh
(cd web && npm ci && npm run build)
```

`web/dist/index.html` ができていれば成功。

### 2.2 流す

```sh
docker compose -f compose.e2e.yaml up --build --abort-on-container-exit --exit-code-from e2e
echo "exit: $?"
```

### 2.3 結果を確かめる

成功したかどうかは 2.5 の出力で確かめる。`e2e/playwright-report` と `e2e/test-results` は次の実行で上書きされるので、失敗したときは、次に流す前に 3章の手順で中身を見ておく。

### 2.4 片付ける

```sh
docker compose -f compose.e2e.yaml down
```

- `storage` のデータは tmpfs なので、`down` で消える（次回は空の状態から始まる）
- ビルドしたイメージも消すときは `down --rmi local`

### 2.5 成功したときの出力

| 確認するところ | 成功のとき |
|---|---|
| `e2e` のログの冒頭 | `deployed N files + config.json to web, evil`（SPA を `web`・`evil` バケットに置いた） |
| `e2e` のログの末尾 | `✓ 1 [chromium] › tests/page-mode.spec.ts … page mode: grant, move to the SPA ticket screen and show the QR` と `1 passed` |
| compose の最後 | `e2e-1 exited with code 0` のあと、ほかのコンテナが止まる |
| `echo "exit: $?"` | `exit: 0` |

## 3. 失敗したとき

### 3.1 レポートとトレースを見る

失敗したテストのトレースは `e2e/test-results/**/trace.zip` に残る（`trace: 'retain-on-failure'`）。ホストで開く:

```sh
(cd e2e && npm ci)                                   # 初回だけ
(cd e2e && npx playwright show-report)               # e2e/playwright-report/index.html を開く
(cd e2e && npx playwright show-trace test-results/<テスト名のフォルダ>/trace.zip)
```

### 3.2 コンテナのログを見る

`--abort-on-container-exit` で止まったあとも、`down` するまではログが残る。

```sh
docker compose -f compose.e2e.yaml logs api        # ゲートウェイ（apigw-local）と Lambda（RIE）のログ。発行の API の構造化ログもここ
docker compose -f compose.e2e.yaml logs storage    # Garage と初期設定スクリプトのログ
docker compose -f compose.e2e.yaml logs e2e
```

### 3.3 よくある失敗

| 症状 | 原因と対処 |
|---|---|
| `/web-dist has no index.html: build web/ first` | `web/dist` がない。2.1 を実行する |
| `getByTestId('grant-page')` などが見つからずタイムアウト | `web/dist` が古い。2.1 で作り直す |
| `API not ready (last status 0)` | `api` が起動していない。`logs api` でビルドや起動のエラーを確かめる |
| `API not ready (last status 404)` など 403 以外 | ゲートウェイは動いているが、関数のルートや起動に問題がある。`logs api` で Lambda 側のエラーを確かめる |
| `storage` が `unhealthy` で `e2e` が始まらない | Garage の初期設定（`web/docker/storage/init.sh`）の失敗。`logs storage` を確かめる |
| 発行の応答が 201 でない、または `access-control-allow-origin` が合わない | API の変更による不一致。`logs api` の構造化ログ（`endpoint`・`status`・エラーコード）を確かめる |
| 2回目以降の `up` がおかしい | 前回のコンテナが残っている。`down` してからやり直す |

## 4. 一部だけ作り直す・流す

| やりたいこと | コマンド |
|---|---|
| API のイメージだけ作り直す | `docker compose -f compose.e2e.yaml build api` |
| ビルドのキャッシュを使わずに作り直す | `docker compose -f compose.e2e.yaml build --no-cache` |
| テストを絞って流す | `docker compose -f compose.e2e.yaml run --rm e2e npx playwright test -g "page mode"`（`storage` と `api` は `depends_on` で起動する。終わったら 2.5 の `down`） |

## 5. 実行の記録

### 5.1 2026-10-14（Claude が実行）

`go` ブランチ（コミット `b77633f`。`master` に Go のコメントの日本語化を足したもの）で、2章の手順をそのまま行った。

| 順 | 行ったこと | 結果 |
|---|---|---|
| 0 | ローカルで起動していたスタブ・API・Web の開発サーバーを止めた。Docker Desktop が止まっていたので起動した（Docker Engine 29.8.2、Docker Compose v5.5.1） | - |
| 1 | 2.1: `web/` で `npm ci` と `npm run build`（画面遷移方式。Tailwind CSS 3.4・valibot・core-js・画像の縮小・バナー・説明文を含む） | `web/dist/index.html` ができた |
| 2 | 2.2: Go 版で `docker compose -f compose.e2e.yaml up --build --abort-on-container-exit --exit-code-from e2e` | **成功**（`exit: 0`。イメージのビルドを含めて約 100 秒） |
| 3 | 2.4: `docker compose -f compose.e2e.yaml down` | コンテナとネットワークを削除（残り 0） |

確かめた出力（2.5 のとおり）:

- `e2e` のログ: `deployed 5 files + config.json to web, evil`
- `✓ 1 tests/page-mode.spec.ts:11:1 › page mode: grant, move to the SPA ticket screen and show the QR`、`1 passed`（約 6 秒）
- `e2e-1 exited with code 0` のあと、`api-1`・`storage-1` も終了コード 0 で止まった
- `api` のログに `exec '/var/runtime/bootstrap'`: ビルドした Lambda 用のバイナリが、Lambda のエミュレーター（RIE）の中で実際に動いた（Go 版は `go` ブランチのコードからイメージを作り直している）

分かったこと:

- `go` ブランチの変更（Go のコメントだけ）は、Lambda 用のバイナリの動作に影響しない（事前に、変更した 28 ファイルをコメントを除いた構文で比べ、コードの違いが 0 件であることも確かめた）
- 2026-10-13〜14 の SPA の変更（Tailwind CSS 3.4、valibot、core-js、画像の縮小、バナー、説明文、チケット画面のボタン、エラーの表示位置）は、E2E のケース1（画面遷移方式）を壊していない
