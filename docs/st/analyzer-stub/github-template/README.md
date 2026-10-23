# GitHub Actions のテンプレート（画像解析サーバーのスタブのリポジトリ用）

実運用では、スタブ（この `analyzer-stub` の内容）を専用のリポジトリに置き、そのリポジトリで CI を動かす。このフォルダは、そのリポジトリの `.github/` の中身のテンプレート。このモノレポでは動かない（`.github/` の外に置いているため）。

| ファイル | 内容 |
|---|---|
| `workflows/ci.yml` | Node・Python・Rust のテスト・型チェック / lint・Lambda 用の zip、VPC 版のコンテナのビルドと起動の確認、CDK（VPC 版のスタブ）のテスト・`mypy`・`synth`、テンプレートの cfn-lint（[../DESIGN.md](../DESIGN.md)「CI」） |

使い方:

1. 専用のリポジトリのルートに、この `analyzer-stub` の内容を置く。ワークフローは、リポジトリのルートを今の `analyzer-stub` として書いてある（`node/`、`python/`、`rust/`、`cdk/`、`testdata/`、`template.yaml`、`network.yaml` がルートにある前提）
2. このフォルダの中身を `.github/` にコピーする（`github-template/workflows/ci.yml` → `.github/workflows/ci.yml`）
3. `stub-rust`・`stub-image` は arm64 の GitHub ホストランナー（`ubuntu-24.04-arm`）を使う。使えない場合は `ubuntu-latest` に `docker/setup-qemu-action` を足す（Rust のビルドは数倍遅くなる）

デプロイのワークフローはない（スタブは手順書で手動でデプロイする。チケット QR API のリポジトリの DEPLOY.md 3章）。

## ワークフローの中身（`workflows/ci.yml`）

スタブは E2E とデプロイでは使わず、手順書で手動でデプロイする（チケット QR API のリポジトリの DEPLOY.md 3章）。

| トリガー | 条件 |
|---|---|
| `pull_request` / `push`（`master`） | すべて（専用のリポジトリなので、パスで絞らない）。イメージの起動確認では、チケット API のリポジトリの `testdata/images` は使わず、その場で作ったバイト列を送る |
| `workflow_dispatch` | 手動 |

| ジョブ（スタブの `ci.yml`） | 内容 | 成果物 |
|---|---|---|
| `infra` | cfn-lint で `template.yaml`（Function URL 版）と `network.yaml`（VPC 版のネットワーク）を検査する | - |
| `cdk` | VPC 版のスタブ（`cdk/`。AWS CDK、Python 3.13）の `unittest`（テンプレートの中身を `aws_cdk.assertions` で確かめる）、`mypy --strict`、`cdk synth`（AWS のアカウントも Docker も要らない）と、生成したテンプレートの cfn-lint | - |
| `stub-node` | スタブ（Node）の `npm test`（依存がないので `npm ci` はしない）と `npm run build` | `stub-node`（Lambda 用の zip） |
| `stub-python` | スタブ（Python 3.13。Lambda のランタイムと同じ）の `python -m unittest`、`mypy --strict`（型チェックのためだけに `mypy` を入れる）、`build.sh` | `stub-python` |
| `stub-rust` | スタブ（Rust）の `build.sh lint`（rustfmt・clippy）、`build.sh test`、`build.sh`（リリースビルド）。arm64 のランナー（`ubuntu-24.04-arm`）で、Amazon Linux 2023 の arm64 のコンテナでビルドする | `stub-rust` |
| `stub-image` | matrix（`node` / `python` / `rust`）。VPC 版のスタブ（DEPLOY.md 3.4）のイメージを arm64 のランナーでビルドし、タスク定義と同じ `STUB_AUTH=none`・読み取り専用のルートファイルシステムで起動して、1回呼んで応答を確かめる | - |

- ジョブはすべて並列に動く
- `stub-rust`・`stub-image` は arm64 の GitHub ホストランナー（`ubuntu-24.04-arm`）を使う。リポジトリの種類やプランによっては使えない（または有料の）場合がある。使えないときは、`ubuntu-latest` に `docker/setup-qemu-action` を足して arm64 を模擬する（動くが、Rust のビルドは数倍遅くなる）

| キャッシュの対象 | 方法 |
|---|---|
| スタブ（Rust）のビルド | キャッシュしない。`build.sh` のビルド環境のイメージ（rustup の導入）と、cargo のレジストリ・`target/` を毎回作り直すので、数分かかる |
