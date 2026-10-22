# 保守（バージョンの更新）

使っている言語・ライブラリ・実行環境のうち、定期的に新しくしなければならないものと、その手順をまとめる。API は Go を採用しているので、Go を中心に書く（Node.js 版の API の更新は [node/README.md](node/README.md) を参照）。

## 1. 現在のバージョン（2026-10-21 時点）

| 順 | 項目 | 現在 | 書いてある場所 |
|---|---|---|---|
| 1 | Go（ツールチェーン） | 1.27.3（2026-10-21 時点の最新） | `go/go.mod` の `go` 行、`go/docker/api.Dockerfile` の `FROM golang:` |
| 2 | Go のライブラリ | 2026-10-21 に `go get -u` で最新にした（下の表） | `go/go.mod`、`go/go.sum` |
| 3 | Lambda のランタイム（Go） | `provided.al2023`（arm64） | `infra/sam/go/template.yaml`、`infra/cloudformation/api.yaml`、`infra/cloudformation/example.yaml` |
| 4 | Node.js | 24（SPA のビルド、E2E、Lambda の `nodejs24.x`） | `web/package.json` の `engines`、`github-template/workflows/ci.yml` の `node-version`、`go/docker/api.Dockerfile` |
| 5 | npm のライブラリ | - | `web/package.json`、`e2e/package.json`（`package-lock.json`） |
| 6 | Python（Lambda） | `python3.13` | `infra/cloudformation/quota-guard.yaml`、`dummy-analyzer/template.yaml`、`github-template/workflows/ci.yml` の `python-version` |
| 7 | Docker イメージ（E2E） | `golang:1.27.3`、`node:24`、`public.ecr.aws/lambda/provided:al2023`、`mcr.microsoft.com/playwright:v1.63.0-noble`、`dxflrs/garage:v2.4.1`、`alpine:3.22` | `go/docker/api.Dockerfile`、`e2e/docker/e2e.Dockerfile`、`web/docker/storage.Dockerfile` |
| 8 | CodeBuild のイメージ（CD） | `aws/codebuild/amazonlinux-aarch64-standard:4.0`（Node.js 24、Go 1.26。Go は `GOTOOLCHAIN=auto` で `go.mod` の版を取る） | `infra/cloudformation/pipeline.yaml`、`cd/buildspec/test.yml` |
| 9 | GitHub Actions | `actions/checkout@v7`、`actions/setup-go@v7` など | `github-template/workflows/*.yml` |

Go のライブラリ（直接使っているもの）:

| ライブラリ | 版 | 使いどころ |
|---|---|---|
| `github.com/aws/aws-lambda-go` | v1.55.1 | Lambda のハンドラ |
| `github.com/aws/aws-sdk-go-v2`（`config`、`service/ssm`） | v1.47.3（`config` v1.33.9、`ssm` v1.80.0） | SSM からソルトを読む |
| `github.com/gabriel-vasile/mimetype` | v1.4.16 | 画像の形式の判定（v1.4.15 は作者が取り下げ（retract）ていたので上げた） |
| `github.com/google/uuid` | v1.6.0 | ID |
| `github.com/makiuchi-d/gozxing` | v0.1.1 | QR の読み取り（テスト） |
| `github.com/skip2/go-qrcode` | v0.0.0-20200617195104-da1b6568686e | QR の生成（更新は止まっている。4章） |
| `go4.org` | v0.0.0-20261019143151-5b882263cdaf | EXIF の向き |
| `golang.org/x/image` | v0.47.0 | 画像の読み込み・縮小 |

`github.com/stretchr/testify`（v1.11.1）と `golang.org/x/xerrors` は、ほかのライブラリが使う間接の依存で、`go mod tidy` が必要な最小の版を選ぶ。新しい版（testify v1.12.1 など）があっても、`go list -m -u` に出るだけで、上げなくてよい。

## 2. 更新の目安

| 項目 | いつ | 理由 |
|---|---|---|
| Go のパッチ版（1.27.x） | 出たら（おおむね毎月） | セキュリティの修正が入る |
| Go のマイナー版（1.28 など） | 出てから 1〜2 か月のうち | Go が保守するのは最新の 2 つのマイナー版だけ（1.28 が出ると 1.26 は保守が終わる） |
| Go のライブラリ | Go を上げるとき、または `govulncheck` で脆弱性が見つかったとき | AWS SDK は頻繁に出るので、毎回追う必要はない |
| Lambda のランタイム | AWS が廃止（deprecation）を告知したとき | 廃止日を過ぎると関数の作成・更新ができなくなる |
| Node.js・Python・Docker イメージ・Actions | Go の更新とまとめて、半年に 1 回くらい | - |

Go は静的なバイナリ（`bootstrap`）を作り、`provided.al2023` は Go の版と関係しないので、Go を上げても Lambda の設定は変えなくてよい。

## 3. Go の更新手順

作業ディレクトリで行う。

### 3.1 最新の版を確かめる

```sh
curl -s 'https://go.dev/dl/?mode=json' | python3 -c 'import json,sys; print([r["version"] for r in json.load(sys.stdin)])'
go version                                        # 手元の Go
(cd go && go list -m -u all | grep '\[')          # 新しい版があるライブラリ（[ ] の中が最新）
```

手元の Go が古ければ、先に入れ替える（Homebrew なら `brew upgrade go`、公式のインストーラーなら https://go.dev/dl/ から）。

### 3.2 `go.mod` を上げる

```sh
cp go/go.mod go/go.sum /tmp/                      # 戻すとき用
(cd go && go get -u ./... && go get go@1.27.3 && go mod tidy)
git diff go/go.mod
```

- `go get -u ./...` は、このモジュールが使っているライブラリ（と、その依存）だけを最新にする（`go get -u all` はテストにしか使わない遠い依存まで上げるので使わない）
- `go get go@<版>` で `go` 行を上げる。`go` 行は「ビルドに要る最低の Go の版」なので、手元・CI・Docker の Go がこれより古いとビルドできない
- `go.mod` に `(retracted)` と出た版（`go list -m -u all` で分かる）は、作者が取り下げた版なので必ず上げる

### 3.3 Docker の Go をそろえる

`go/docker/api.Dockerfile` の `FROM golang:<版>` を、`go.mod` の `go` 行と同じ版にする。

```sh
sed -i '' 's/^FROM golang:[0-9.]* AS go-build/FROM golang:1.27.3 AS go-build/' go/docker/api.Dockerfile
grep -n '^FROM golang' go/docker/api.Dockerfile
```

GitHub Actions（`ci.yml`）は `go-version-file: go/go.mod` で `go.mod` から版を読むので、直さなくてよい。

### 3.4 確かめる

| 順 | コマンド | 成功のとき |
|---|---|---|
| 1 | `(cd go && make test)` | `go vet` が何も出さず、すべて `ok` |
| 2 | `(cd go && gofmt -l .)` | 何も出ない（新しい Go で書式の規則が変わることがある） |
| 3 | `(cd go && make build)` | `go/bin/ticketqr.zip` と `go/bin/exampleqr.zip` ができる |
| 4 | `(cd go && go mod verify)` | `all modules verified` |
| 5 | `(cd go && go run golang.org/x/vuln/cmd/govulncheck@latest ./...)` | `No vulnerabilities found.` |
| 6 | `(cd infra/sam/go && sam build)` | `Build Succeeded` |
| 7 | E2E（[E2E_RUN.md](E2E_RUN.md) 2章） | `exit: 0`。Docker の `golang` イメージが変わるので、`--build` で作り直す |

1〜6 は 2026-10-21 の更新（Go 1.27.1 → 1.27.3、ライブラリ）で通ったことを確かめた。7（E2E）はまだ流していない。

### 3.5 デプロイ

アプリのコードは変わらず、Lambda の zip を作り直すだけ。今のデプロイの手順（[go/DEPLOY.md](go/DEPLOY.md)、または GitHub Actions の `deploy.yml`。[CI.md](CI.md) 4章）をそのまま流せばよい。

### 3.6 戻す

```sh
cp /tmp/go.mod /tmp/go.sum go/
git checkout go/docker/api.Dockerfile
```

## 4. 気をつけること

| 項目 | 内容 |
|---|---|
| `skip2/go-qrcode` | 2020 年から更新がない。今は動いているが、Go の新しい版でビルドやテストが失敗したら、別のライブラリへの置き換えを考える |
| 画像のライブラリ（`x/image`、`go4.org`、`mimetype`） | 画像の判定・縮小・向きの結果が変わると、発行の判定に響く。`internal/imageinput` のテストが通ることを必ず確かめる |
| AWS SDK | 版の上げ下げで動きが変わることはまれだが、SSM の読み込みはローカルのテストでは通らないので、デプロイ後に 1 回発行して確かめる |
| Go のマイナー版を上げるとき | リリースノート（https://go.dev/doc/devel/release）の「Minor changes to the library」で、`net/http`・`image`・`crypto/hmac` の変更を確かめる |

## 5. Go 以外の更新手順

| 項目 | 手順 | 確かめ方 |
|---|---|---|
| npm のライブラリ（`web/`、`e2e/`） | `(cd web && npm outdated)` で確かめ、`npm update`（メジャー版は `npm install <名前>@latest` で 1 つずつ） | `(cd web && npm test && npm run typecheck && npm run build)`、E2E |
| Playwright | `e2e/package.json` の `@playwright/test` と `e2e/docker/e2e.Dockerfile` の `playwright:v<版>-noble` を同じ版にする | E2E |
| Node.js のメジャー版 | `engines`・`node-version`・Dockerfile の `node:`・Lambda の `nodejs<版>.x` をまとめて変える | 上と同じ |
| Python の Lambda | `quota-guard.yaml`・`dummy-analyzer/template.yaml` の `Runtime`、`ci.yml` の `python-version` | `cfn-lint`、`(cd dummy-analyzer && sam build)` |
| Docker イメージ（`garage`、`alpine`） | `web/docker/storage.Dockerfile` の版 | E2E |
| GitHub Actions | `github-template/workflows/*.yml` の `@v<版>` | CI を 1 回流す |
