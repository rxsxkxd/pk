# Docker Compose + Playwright

Go API、Vite + Vue + TypeScript フロントエンド、Playwright JavaScript E2E テストをそれぞれ別コンテナで実行する構成です。

```text
browser (localhost:8080) -> front (Vite dev / Node.js 22) -> api (Go)
                                      ^
                         playwright (E2E container)
```

## 起動

```bash
docker compose up --build -d api front
```

フロントエンドは http://localhost:8080 で開けます。API はフロントの `/api` 経由でアクセスします。

開発時は `front/` がコンテナへ bind mount されるため、Vue/TypeScript ファイルの保存が Vite の HMR で反映されます。依存パッケージはホストと共有しない `front_node_modules` ボリュームに保持します。

## E2E テスト

テスト用コンテナを起動し、終了後に削除します。

```bash
docker compose --profile e2e run --rm playwright
```

すべてを一度に実行する場合は次のとおりです（Playwright の終了コードを確認したら `down` してください）。

```bash
docker compose --profile e2e up --build --abort-on-container-exit --exit-code-from playwright
docker compose down
```

## コンテナの責務

- `api`: Go による API サーバー（Compose ネットワーク内のポート `3000`）
- `front`: Node.js 22 上の Vite dev で Vue + TypeScript アプリを配信。HMR を有効にし、Vite のプロキシ設定で `/api/` を `api` へ転送
- `playwright`: Node.js 24 で Playwright JavaScript と Chromium を実行

テストコンテナからの対象 URL は `BASE_URL=http://front:5173` です。Docker ネットワーク内ではサービス名をホスト名に使い、Vite dev の待受ポート `5173` を指定します。
