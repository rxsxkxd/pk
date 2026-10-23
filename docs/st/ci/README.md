# CI（GitHub Actions。単体テストだけ）

pull request と master への push のたびに、GitHub Actions で単体テストを流す。ビルド・E2E・デプロイはしない。それらは CD（[../cd/README.md](../cd/README.md)。CodePipeline / CodeBuild）が受け持つ。

> **状態（2026-10-23）**: ワークフローを単体テストだけに絞り、手元の act で 2 つのジョブの成功を確かめた（Go のテスト全件、Vitest 115 件）。GitHub 上ではまだ動かしていない（専用のリポジトリへの push 前）。

## 1. CI と CD の分担

| | CI（このフォルダ） | CD（[../cd/](../cd/)） |
|---|---|---|
| 動かす場所 | GitHub Actions | AWS CodePipeline / CodeBuild |
| きっかけ | pull request、master への push | master への push |
| やること | 単体テスト（Go・SPA） | 単体テスト → ビルド → E2E（今は空）→ Lambda のコードと SPA のファイルの差し替え |
| AWS の権限 | 持たない | Deploy の段だけが持つ |

- CI は、マージの前に早く失敗を知らせるためのもの。CD は CI の結果を受け取らず、ソースから同じテストをもう一度流してからビルドする
- CI が通らなくても、master に入ったコミットは CD が流れる。CD の Test の段で同じテストが落ちるので、デプロイはされない。マージの前に止めたいときは、GitHub のブランチ保護で CI のジョブを必須にする

## 2. ワークフロー（`workflows/ci.yml`）

| トリガー | 条件 |
|---|---|
| `pull_request` | すべての pull request（専用のリポジトリなので、パスで絞らない） |
| `push` | `master` への push |
| `workflow_dispatch` | 手動 |

| ジョブ | コマンド | 内容 |
|---|---|---|
| `go` | `make -C go test` | `go vet` と Go の単体テスト |
| `web` | `npm --prefix web ci`、`npm --prefix web run format:check`、`npm --prefix web test` | 依存を入れ、Prettier と Vitest を流す |

- 2 つのジョブは並列に動く。同じブランチで新しい実行が始まると、古い実行は取り消す（`concurrency`）
- 単体テストは外に通信しない（画像解析サーバーと `fetch` は偽物に差し替えてある。[../cd/README.md](../cd/README.md) 3章）
- Prettier の検査は単体テストではないが、CD の Test の段と同じ検査にそろえるために入れている（ここで落ちるものは CD でも落ちる）
- 成果物は作らない。Node.js 版（`node/`）、テンプレートの cfn-lint、E2E は入れていない

キャッシュ:

| 対象 | 方法 |
|---|---|
| Go のモジュールとビルド | `actions/setup-go` の標準のキャッシュ（`go.sum` で判定） |
| npm | `actions/setup-node` の `cache: npm`（`web/package-lock.json` で判定） |

## 3. 失敗したとき

失敗したテストは、ジョブのログに出る。手元では同じコマンドで再現できる（`make -C go test`、`npm --prefix web test`）。

## 4. 置き場所と使い方

GitHub は、リポジトリのルートの `.github/workflows/` にあるファイルだけを動かす。このモノレポでは作業ディレクトリがルートではないので、ワークフローはテンプレートとしてここに置いている（このモノレポでは動かない）。

1. 専用のリポジトリのルートに、作業ディレクトリの内容（`analyzer-stub/` を除く）を置く。ワークフローは、リポジトリのルートを今の作業ディレクトリとして書いてある（`go/`・`web/` がルートにある前提）
2. `ci/workflows/ci.yml` を `.github/workflows/ci.yml` にコピーする
3. 必要なら、GitHub のブランチ保護で `Go (vet, unit tests)`・`Web (format, unit tests)` を必須のチェックにする

画像解析サーバーのスタブの CI は、スタブのリポジトリのもの（[../analyzer-stub/github-template/README.md](../analyzer-stub/github-template/README.md)）。

## 5. ローカルでの確認

専用のリポジトリと同じ形（ルートに `.github/workflows/`）のコピーを作って確かめる。

```sh
# 作業ディレクトリの内容（analyzer-stub/ と node_modules を除く）を作業用のディレクトリにコピーし、ワークフローを置く
WORK=$(mktemp -d)
rsync -a --exclude analyzer-stub --exclude node_modules ./ "$WORK/"
mkdir -p "$WORK/.github/workflows" && cp ci/workflows/ci.yml "$WORK/.github/workflows/"
cd "$WORK" && git init -q .

# 構文と、よくある誤りの検査
go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
actionlint

# CI を Docker の中で実行する（nektos/act）
go install github.com/nektos/act@v0.2.89
act workflow_dispatch -W .github/workflows/ci.yml -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

- Apple シリコンの Mac では `--container-architecture linux/arm64` を付ける
