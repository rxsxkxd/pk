# CI / CD（GitHub Actions）

> **状態**: CI（ビルド・単体テスト・E2E）は定義済みで、ローカルの act（GitHub Actions のローカル実行ツール）で全ジョブ（go、node、web、infra、e2e の go / node）の成功を確認済み（成果物のアクションだけ、act の制約で v4 に置き換えて実行。5章）。GitHub 上ではまだ動かしていない（リポジトリへの push 前）。画像解析サーバーのスタブの CI（2026-10-08 にチケット API の CI から分けた）は、actionlint と、各ステップと同じコマンドの手元での実行で確認した（act では未確認）。
>
> **ワークフローの置き場所（2026-10-08）**: 実運用では、チケット QR API とスタブをそれぞれ専用のリポジトリに置いて CI / CD を動かす。そのため、ワークフローは `.github/` ではなくテンプレートとして置く: チケット QR API は `github-template/workflows/`（`ci.yml`・`deploy.yml`）、スタブは `analyzer-stub/github-template/workflows/ci.yml`。各リポジトリでは、それぞれの `github-template/` の中身を `.github/` にコピーして使う（各 `github-template/README.md`）。ワークフローは、リポジトリのルートを今の `docs/st`（スタブは `analyzer-stub`）として書いてある。このモノレポでは動かない。デプロイ（4章）は定義だけで、未検証（AWS 側と GitHub 側の準備が必要。4.2）。

関連: デプロイの手順は [DEPLOY.md](DEPLOY.md)（全体と共通の準備）・[go/DEPLOY.md](go/DEPLOY.md)・[node/DEPLOY.md](node/DEPLOY.md)・[web/DEPLOY.md](web/DEPLOY.md)、E2E の構成は [E2E.md](E2E.md)。

## 1. 全体像

```
チケット QR API のリポジトリ（github-template/workflows/ → .github/workflows/）

pull request / master への push
  └─ CI（ci.yml）: チケット API と SPA
       ├─ go     Go のテスト・ビルド       → 成果物 lambda-go（ticketqr.zip、exampleqr.zip）
       ├─ node   Node の型チェック・テスト・ビルド → 成果物 lambda-node
       ├─ web    SPA のテスト・ビルド       → 成果物 web-dist
       ├─ infra  CloudFormation テンプレート（infra/）の cfn-lint
       └─ e2e    （go・node・web の後）matrix: go / node
                  web-dist を使い、compose（storage + api + e2e）で Playwright を流す

手動実行（workflow_dispatch: 実装と環境を選ぶ）
  └─ Deploy（deploy.yml）
       ├─ ci      ci.yml をそのまま呼ぶ（同じ成果物を作る。E2E が通らなければデプロイしない）
       └─ deploy  GitHub の environment（承認ルール）→ OIDC で AWS のロールを引き受ける
                  zip のアップロード → API のスタック → Web のスタック → CORS → SPA のアップロード → スモークテスト

スタブのリポジトリ（analyzer-stub/github-template/workflows/ → .github/workflows/）

pull request / master への push
  └─ CI（ci.yml）: 画像解析サーバーのスタブ
       ├─ infra        スタブのテンプレート（template.yaml・network.yaml）の cfn-lint
       ├─ cdk          VPC 版のスタブ（AWS CDK、Python）のテスト・mypy・synth と、生成したテンプレートの cfn-lint
       ├─ stub-node / stub-python / stub-rust  テスト・型チェックや lint・Lambda 用の zip → 成果物 stub-*
       └─ stub-image   matrix: node / python / rust  VPC 版のスタブのイメージのビルドと起動の確認
```

| ファイル | 内容 |
|---|---|
| テンプレート（このモノレポでの置き場所） | 専用のリポジトリでの置き場所 | 内容 |
|---|---|---|
| `github-template/workflows/ci.yml` | `.github/workflows/ci.yml` | チケット API と SPA のビルド・単体テスト・E2E。`workflow_call` で、デプロイからも呼ばれる |
| `github-template/workflows/deploy.yml` | `.github/workflows/deploy.yml` | AWS へのデプロイ（手動実行）。未検証 |
| `analyzer-stub/github-template/workflows/ci.yml` | スタブのリポジトリの `.github/workflows/ci.yml` | 画像解析サーバーのスタブのテスト・ビルド（3.5）。デプロイのワークフローはない（スタブは手順書で手動でデプロイする。DEPLOY.md 3章） |

ワークフローのファイルは、GitHub の決まりでリポジトリのルートの `.github/workflows/` に置く。テンプレートは、各リポジトリのルート（チケット QR API は今の `docs/st`、スタブは今の `analyzer-stub`）で動く前提で書いてあり、`working-directory` の指定はない。

## 2. 方針

- **ビルドは1回だけ**: CI が作った成果物（zip と SPA の `dist`）を、E2E とデプロイでそのまま使う。デプロイの前に別のビルドはしない
- **E2E を通ったものだけをデプロイする**: デプロイのワークフローは、最初に CI を丸ごと実行する
- **長期の AWS の鍵を持たない**: GitHub の OIDC で、デプロイ用の IAM ロールを一時的に引き受ける
- **手順は各手順書と同じ**: ワークフローの各ステップは、go/DEPLOY.md・node/DEPLOY.md（4-A.1）と web/DEPLOY.md（3・5・6章）の CloudFormation の手順をそのまま実行する。手順を変えるときは、両方を直す

## 3. CI（チケット QR API の `ci.yml`）

### 3.1 トリガー

| トリガー | 条件 |
|---|---|
| `pull_request` | すべての pull request（専用のリポジトリなので、パスで絞らない） |
| `push` | `master` への push |
| `workflow_dispatch` | 手動 |
| `workflow_call` | `deploy.yml` から呼ばれたとき |

同じブランチで新しい実行が始まると、古い実行は取り消す（`concurrency`）。デプロイから呼ばれた実行は別のグループになるので、push の CI に取り消されない。

### 3.2 ジョブ

| ジョブ | 内容 | 成果物 |
|---|---|---|
| `go` | `make -C go test`（vet・テスト）、`make -C go build`（arm64 の Lambda 用 zip） | `lambda-go` |
| `node` | `npm ci`、型チェック、prettier、テスト、`npm run build`（esbuild と zip） | `lambda-node` |
| `web` | `npm ci`、prettier、テスト（Vitest）、`npm run build`（vue-tsc と vite） | `web-dist` |
| `infra` | cfn-lint で `infra/cloudformation/*.yaml` を検査する | - |
| `e2e` | `go`・`node`・`web` の後に、matrix（`go` / `node`）で実行する。`web-dist` を `web/dist` に置き、`docker compose -f compose.e2e.yaml up` を実行する | `e2e-go` / `e2e-node`（Playwright のレポート、トレース、失敗したときのコンテナのログ） |

- `go`・`node`・`web`・`infra` は並列に動く
- E2E の `api` コンテナは、ソースから Lambda 用のビルドをやり直す（Docker のマルチステージビルド）。`lambda-*` の zip は使わない。E2E で確かめるのは「同じソースから同じ手順で作ったもの」になる
- 成果物の保持期間は7日

### 3.3 キャッシュ

| 対象 | 方法 |
|---|---|
| Go のモジュールとビルド | `actions/setup-go` の標準のキャッシュ（`go.sum` で判定） |
| npm | `actions/setup-node` の `cache: npm`（各 `package-lock.json` で判定） |
| E2E の Docker イメージ | まだキャッシュしていない（毎回ビルドする）。必要になったら、compose の `build.cache_from` / `cache_to` に `type=gha` を指定する |

### 3.4 失敗したとき

- 単体テストの失敗は、ジョブのログに出る
- E2E の失敗は、成果物 `e2e-go` / `e2e-node` を取り出す
  - `playwright-report/index.html`: 結果の一覧
  - `test-results/**/trace.zip`: `npx playwright show-trace trace.zip` で、操作・通信・画面を1手ずつ再生できる
  - `compose-logs.txt`: `storage`（Garage）と `api`（ゲートウェイと Lambda）のログ

### 3.5 画像解析サーバーのスタブの CI（スタブのリポジトリの `ci.yml`）

チケット API とは別のリポジトリのワークフロー（テンプレートは `analyzer-stub/github-template/workflows/ci.yml`）。スタブは E2E とデプロイのワークフローでは使わず、手順書で手動でデプロイする（DEPLOY.md 3章）。

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
| スタブ（Rust）のビルド | まだキャッシュしていない。`build.sh` のビルド環境のイメージ（rustup の導入）と、cargo のレジストリ・`target/` を毎回作り直すので、数分かかる。必要になったら、`actions/cache` で cargo のディレクトリを保存する |

## 4. デプロイ（チケット QR API の `deploy.yml`）

> **見直し中**: デプロイを CodePipeline / CodeBuild に移す案がある（[CD_CI.md](CD_CI.md)）。採用したら、この章と `deploy.yml` は廃止する。

> 未検証。4.2 の準備をしてから、`dev` で試す。

### 4.1 流れ

手動で実行し、**実装**（`go` / `node`）、**構成**（`layout`。`direct` = 直結、`unified` = 統合。web/DEPLOY.md の冒頭）と **環境**（GitHub の environment。例: `dev`、`prod`）を選ぶ。画像の上限は、environment の変数 `MAX_IMAGE_BYTES`（任意。既定 4194304）で API と `config.json` の両方に入る。

| ステップ | 内容 | 手順書 |
|---|---|---|
| CI | `ci.yml` を呼ぶ。E2E まで通らなければ、ここで止まる | - |
| 承認 | environment に承認者を設定していれば、ここで承認を待つ | - |
| AWS の認証 | OIDC で `AWS_DEPLOY_ROLE_ARN` のロールを引き受ける | - |
| zip のアップロード | `s3://$ARTIFACT_BUCKET/ticketqr/{impl}/{sha}-{試行回数}/` に置く（接頭辞を毎回変えるので、Lambda のコードが必ず更新される） | {impl}/DEPLOY.md 4-A.1（zip のアップロード） |
| API のスタック | `api.yaml` を `ticketqr-{impl}` にデプロイし、`ApiUrl`・`ApiDomain` を取り出す。統合で、Web のスタックがすでに統合になっていれば、`PublicBaseUrl` にその CloudFront の URL を渡す | {impl}/DEPLOY.md 4-A.1（スタックのデプロイ） |
| Web のスタック | `web.yaml` を `ticketqr-web-{impl}` にデプロイし（直結は `ApiBaseUrl`、統合は `ApiOriginDomain` を渡す）、バケット・ディストリビューション・URL を取り出す | web/DEPLOY.md 3.1・3.2 |
| API の公開 URL（統合だけ） | 初回（または直結からの切り替え）だけ、API を `PublicBaseUrl=$WEB_URL` でもう一度デプロイする | web/DEPLOY.md 3.2 の 3 |
| CORS（直結だけ） | API Gateway の CORS に SPA のオリジンを入れる（暫定。`api.yaml` に CORS の設定が入るまで） | web/DEPLOY.md 5章 |
| SPA のアップロード | `config.json`（`apiBaseUrl`（統合では `""`）、`modes`、`maxImageBytes`）を作り、`dist` と一緒に S3 に置いて、CloudFront のキャッシュを消す | web/DEPLOY.md 6章 |
| スモークテスト | SPA と `config.json` が取れること、発行できること（直結: API に直接送り、CORS のヘッダーが付くこと。統合: CloudFront の `/v1/tickets` に送り、`qrUrl` が CloudFront の URL であること）、QR 画像 API が PNG を返すこと。URL はジョブのサマリーに出す | {impl}/DEPLOY.md 7章、web/DEPLOY.md 7章 |

同じ環境・同じ実装のデプロイは、同時に1つだけ動く（`concurrency`。実行中のものは取り消さない）。

### 4.2 準備（初回だけ）

#### AWS 側

| 準備 | 方法 |
|---|---|
| 成果物バケット | DEPLOY.md 2章 |
| 署名用の salt | {impl}/DEPLOY.md 3章（`/ticketqr/{impl}/signing-salt`。実装ごと） |
| GitHub の OIDC プロバイダー | IAM の ID プロバイダーに `token.actions.githubusercontent.com`（対象者 `sts.amazonaws.com`）を追加する（アカウントに1つ） |
| デプロイ用の IAM ロール | 下の信頼ポリシーと権限で作る（環境ごとに分けてもよい） |

信頼ポリシー（このリポジトリの、指定した environment のジョブだけが引き受けられる）:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:rxsxkxd/pk:environment:dev"
      }
    }
  }]
}
```

ロールに必要な権限（目安。最初は広めに付けて動かし、CloudTrail を見て絞る）:

| 対象 | 権限 |
|---|---|
| CloudFormation | `cloudformation:*`（スタック `ticketqr-*` に限定する） |
| IAM（Lambda の実行ロールをスタックが作るため） | `iam:CreateRole` / `DeleteRole` / `GetRole` / `PassRole` / `PutRolePolicy` / `DeleteRolePolicy` / `AttachRolePolicy` / `DetachRolePolicy`（ロール名 `ticketqr-*` に限定する） |
| Lambda・API Gateway・ログ | `lambda:*`、`apigateway:*`（`/apis*`）、`logs:CreateLogGroup` / `DeleteLogGroup` / `PutRetentionPolicy` |
| S3 | 成果物バケットへの `s3:PutObject`。Web のバケットの作成と、`s3:PutObject` / `DeleteObject` / `ListBucket` / `PutBucketPolicy` |
| CloudFront | ディストリビューション、OAC、Response Headers Policy の作成・更新、`cloudfront:CreateInvalidation` |
| SSM | 不要（salt はデプロイの時点では読まない。Lambda の実行ロールが実行時に読む） |

#### GitHub 側

| 設定 | 内容 |
|---|---|
| environment | `dev`、`prod` など。`prod` には承認者（Required reviewers）を設定する |
| environment の変数（Variables） | `AWS_REGION`（例: `ap-northeast-1`）、`AWS_DEPLOY_ROLE_ARN`、`ARTIFACT_BUCKET`、`WEB_MODES`（任意。既定は `["page"]`） |

秘密の値（Secrets）は使わない。ロールの ARN やバケット名は秘密ではないので、変数に入れる。

### 4.3 ロールバック

前のコミットを選んで、デプロイのワークフローをもう一度実行する（`Run workflow` でブランチやタグを選ぶ）。zip の接頭辞はコミットごとに違うので、前のコードに戻る。CloudFormation の更新が失敗したときは、スタックが自動で元に戻る。

### 4.4 まだ対応していないこと

| 項目 | 状態 |
|---|---|
| example.com の QR のスタック（`example.yaml`） | デプロイしない。必要になったら、同じ形のステップを足す |
| 画像解析サーバー（`AnalyzerMode=http`） | `mock` のまま。パラメータを environment の変数で渡す形にする |
| API の CORS のテンプレート化 | `api.yaml` に `CorsConfiguration` を入れたら、CORS のステップを消す |
| Origin の照合（`ALLOWED_ORIGINS`） | 未実装（E2E.md 4.2）。実装したら、API のスタックに SPA のオリジンを渡す |
| master への push で `dev` に自動デプロイ | 今は手動だけ。安定したら `push` のトリガーを足す |
| 解析サーバーのスタブのデプロイ | 入れない（スタブは別のリポジトリ。テストとビルドはそのリポジトリの CI（3.5）、デプロイは手順書で手動） |

## 5. ローカルでの確認

ワークフローを GitHub に push する前に、手元で確かめる。テンプレートは `.github/` の外にあるので、専用のリポジトリと同じ形（ルートに `.github/workflows/`）のコピーを作って確かめる。

```sh
# チケット QR API: docs/st の内容（analyzer-stub/ と node_modules を除く）を作業用のディレクトリにコピーし、
# テンプレートを .github/ に置く（スタブも同じ要領で、analyzer-stub の内容と analyzer-stub/github-template/）
WORK=$(mktemp -d)
rsync -a --exclude analyzer-stub --exclude node_modules ./ "$WORK/"
mkdir -p "$WORK/.github" && cp -R github-template/workflows "$WORK/.github/"
cd "$WORK" && git init -q .

# 構文と、よくある誤りの検査
go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
actionlint

# CI を Docker の中で実行する（nektos/act）
go install github.com/nektos/act@v0.2.89
act workflow_dispatch -W .github/workflows/ci.yml --bind \
  --artifact-server-path /tmp/act-artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

- `--bind` は、作業ディレクトリをコンテナにそのままマウントする（E2E のジョブの中の `docker compose` が、ホストのパスでファイルをマウントするため）。そのため、ジョブの中の `npm ci` が `node_modules` を Linux 用のもので作る。上のように `node_modules` を含まないコピーで実行する
- **act の制約**: act に内蔵された成果物のサーバーは、`actions/upload-artifact@v7` / `download-artifact@v8` のプロトコルに対応していない（`Failed to CreateArtifact: Unexpected end of JSON input` になる）。ローカルで流すときは、コピーしたワークフローの中だけ、この2つを `@v4` に置き換える（リポジトリのワークフローは最新版のまま）
  ```sh
  sed -i '' 's#upload-artifact@v7#upload-artifact@v4#; s#download-artifact@v8#download-artifact@v4#' .github/workflows/ci.yml
  ```
- Apple シリコンの Mac では `--container-architecture linux/arm64` を付ける（Lambda 用の zip は arm64 用なので、どちらでも同じものができる）
- デプロイのワークフローは、AWS の認証が必要なので act では確かめられない
