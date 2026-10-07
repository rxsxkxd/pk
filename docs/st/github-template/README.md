# GitHub Actions のテンプレート（チケット QR API のリポジトリ用）

実運用では、チケット QR API（この `docs/st` の内容。`analyzer-stub/` を除く）を専用のリポジトリに置き、そのリポジトリで CI / CD を動かす。このフォルダは、そのリポジトリの `.github/` の中身のテンプレート。このモノレポでは動かない（`.github/` の外に置いているため）。

| ファイル | 内容 |
|---|---|
| `workflows/ci.yml` | ビルド・単体テスト・E2E（[../CI.md](../CI.md) 3章）。`deploy.yml` からも呼ばれる |
| `workflows/deploy.yml` | AWS へのデプロイ（手動実行。[../CI.md](../CI.md) 4章）。未検証 |

使い方:

1. 専用のリポジトリのルートに、この `docs/st` の内容（`analyzer-stub/` を除く）を置く。ワークフローは、リポジトリのルートを今の `docs/st` として書いてある（`go/`、`node/`、`web/`、`infra/`、`compose.e2e.yaml` などがルートにある前提）
2. このフォルダの中身を `.github/` にコピーする（`github-template/workflows/ci.yml` → `.github/workflows/ci.yml`）。`deploy.yml` は `./.github/workflows/ci.yml` を呼ぶので、ファイル名を変えない
3. デプロイを使う場合は、CI.md 4.2 の準備（IAM ロール、environment、変数）を行う

画像解析サーバーのスタブのテンプレートは、[../analyzer-stub/github-template/](../analyzer-stub/github-template/)。
