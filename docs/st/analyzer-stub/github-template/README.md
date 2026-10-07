# GitHub Actions のテンプレート（画像解析サーバーのスタブのリポジトリ用）

実運用では、スタブ（この `analyzer-stub` の内容）を専用のリポジトリに置き、そのリポジトリで CI を動かす。このフォルダは、そのリポジトリの `.github/` の中身のテンプレート。このモノレポでは動かない（`.github/` の外に置いているため）。

| ファイル | 内容 |
|---|---|
| `workflows/ci.yml` | Node・Python・Rust のテスト・型チェック / lint・Lambda 用の zip、VPC 版のコンテナのビルドと起動の確認、テンプレートの cfn-lint（[../DESIGN.md](../DESIGN.md)「CI」） |

使い方:

1. 専用のリポジトリのルートに、この `analyzer-stub` の内容を置く。ワークフローは、リポジトリのルートを今の `analyzer-stub` として書いてある（`node/`、`python/`、`rust/`、`testdata/`、`template.yaml`、`vpc-template.yaml` がルートにある前提）
2. このフォルダの中身を `.github/` にコピーする（`github-template/workflows/ci.yml` → `.github/workflows/ci.yml`）
3. `stub-rust`・`stub-image` は arm64 の GitHub ホストランナー（`ubuntu-24.04-arm`）を使う。使えない場合は `ubuntu-latest` に `docker/setup-qemu-action` を足す（Rust のビルドは数倍遅くなる）

デプロイのワークフローはない（スタブは手順書で手動でデプロイする。チケット QR API のリポジトリの DEPLOY.md 3章）。
