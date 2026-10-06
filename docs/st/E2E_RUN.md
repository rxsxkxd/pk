# E2E の手動実行手順

ローカルの Docker Compose で E2E（3つのコンテナ: `storage`・`api`・`e2e`）を手で流すための手順。構成と設計の理由は [E2E.md](E2E.md)、GitHub Actions での実行は [CI.md](CI.md) を参照。

コマンドはすべて `docs/st` で実行する。

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

### 2.2 Go 版で流す

```sh
docker compose -f compose.e2e.yaml up --build --abort-on-container-exit --exit-code-from e2e
echo "exit: $?"
```

### 2.3 結果を確かめる（Go 版）

成功したかどうかは 2.6 の出力で確かめる。`e2e/playwright-report` と `e2e/test-results` は次の実行で上書きされるので、失敗したときは Node 版を流す前に 3章の手順で中身を見ておく。

### 2.4 Node 版で流す

```sh
API_IMPL=node docker compose -f compose.e2e.yaml up --build --abort-on-container-exit --exit-code-from e2e
echo "exit: $?"
```

### 2.5 片付ける

```sh
docker compose -f compose.e2e.yaml down
```

- `storage` のデータは tmpfs なので、`down` で消える（次回は空の状態から始まる）
- ビルドしたイメージも消すときは `down --rmi local`

### 2.6 成功したときの出力

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
| `storage` が `unhealthy` で `e2e` が始まらない | Garage の初期設定（`docker/storage/init.sh`）の失敗。`logs storage` を確かめる |
| 発行の応答が 201 でない、または `access-control-allow-origin` が合わない | API の変更による不一致。`logs api` の構造化ログ（`endpoint`・`status`・エラーコード）を確かめる |
| 2回目以降の `up` がおかしい | 前回のコンテナが残っている。`down` してからやり直す |

## 4. 一部だけ作り直す・流す

| やりたいこと | コマンド |
|---|---|
| API のイメージだけ作り直す | `docker compose -f compose.e2e.yaml build api`（Node 版は先頭に `API_IMPL=node`） |
| ビルドのキャッシュを使わずに作り直す | `docker compose -f compose.e2e.yaml build --no-cache` |
| テストを絞って流す | `docker compose -f compose.e2e.yaml run --rm e2e npx playwright test -g "page mode"`（`storage` と `api` は `depends_on` で起動する。終わったら 2.5 の `down`） |
