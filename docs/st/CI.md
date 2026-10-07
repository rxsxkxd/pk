# CI / CD（GitHub Actions）

> **状態**: CI（ビルド・単体テスト・E2E）は定義済みで、ローカルの act（GitHub Actions のローカル実行ツール）で全ジョブ（go、node、web、infra、e2e の go / node）の成功を確認済み（成果物のアクションだけ、act の制約で v4 に置き換えて実行。5章）。GitHub 上ではまだ動かしていない（リポジトリへの push 前）。デプロイ（4章）は定義だけで、未検証（AWS 側と GitHub 側の準備が必要。4.2）。

関連: デプロイの手順は [DEPLOY.md](DEPLOY.md)（全体と共通の準備）・[go/DEPLOY.md](go/DEPLOY.md)・[node/DEPLOY.md](node/DEPLOY.md)・[web/DEPLOY.md](web/DEPLOY.md)、E2E の構成は [E2E.md](E2E.md)。

## 1. 全体像

```
pull request / master への push（docs/st/** が変わったとき）
  └─ st CI（.github/workflows/st-ci.yml）
       ├─ go     Go のテスト・ビルド       → 成果物 lambda-go（ticketqr.zip、exampleqr.zip）
       ├─ node   Node の型チェック・テスト・ビルド → 成果物 lambda-node
       ├─ web    SPA のテスト・ビルド       → 成果物 web-dist
       ├─ infra  CloudFormation テンプレートの cfn-lint
       └─ e2e    （go・node・web の後）matrix: go / node
                  web-dist を使い、compose（storage + api + e2e）で Playwright を流す

手動実行（workflow_dispatch: 実装と環境を選ぶ）
  └─ st deploy（.github/workflows/st-deploy.yml）
       ├─ ci      st CI をそのまま呼ぶ（同じ成果物を作る。E2E が通らなければデプロイしない）
       └─ deploy  GitHub の environment（承認ルール）→ OIDC で AWS のロールを引き受ける
                  zip のアップロード → API のスタック → Web のスタック → CORS → SPA のアップロード → スモークテスト
```

| ファイル | 内容 |
|---|---|
| `.github/workflows/st-ci.yml` | ビルド・単体テスト・E2E。`workflow_call` で、デプロイからも呼ばれる |
| `.github/workflows/st-deploy.yml` | AWS へのデプロイ（手動実行）。未検証 |

ワークフローのファイルは、GitHub の決まりでリポジトリのルートの `.github/workflows/` に置く。各ジョブの作業ディレクトリは `docs/st`。

## 2. 方針

- **ビルドは1回だけ**: CI が作った成果物（zip と SPA の `dist`）を、E2E とデプロイでそのまま使う。デプロイの前に別のビルドはしない
- **E2E を通ったものだけをデプロイする**: デプロイのワークフローは、最初に CI を丸ごと実行する
- **長期の AWS の鍵を持たない**: GitHub の OIDC で、デプロイ用の IAM ロールを一時的に引き受ける
- **手順は各手順書と同じ**: ワークフローの各ステップは、go/DEPLOY.md・node/DEPLOY.md（4-A.1）と web/DEPLOY.md（3・5・6章）の CloudFormation の手順をそのまま実行する。手順を変えるときは、両方を直す

## 3. CI（`st-ci.yml`）

### 3.1 トリガー

| トリガー | 条件 |
|---|---|
| `pull_request` | `docs/st/**` か、このワークフローが変わったとき |
| `push` | `master` で、同じ条件 |
| `workflow_dispatch` | 手動 |
| `workflow_call` | `st-deploy.yml` から呼ばれたとき |

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

## 4. デプロイ（`st-deploy.yml`）

> **見直し中**: デプロイを CodePipeline / CodeBuild に移す案がある（[CD_CI.md](CD_CI.md)）。採用したら、この章と `st-deploy.yml` は廃止する。

> 未検証。4.2 の準備をしてから、`dev` で試す。

### 4.1 流れ

手動で実行し、**実装**（`go` / `node`）と **環境**（GitHub の environment。例: `dev`、`prod`）を選ぶ。

| ステップ | 内容 | 手順書 |
|---|---|---|
| CI | `st-ci.yml` を呼ぶ。E2E まで通らなければ、ここで止まる | - |
| 承認 | environment に承認者を設定していれば、ここで承認を待つ | - |
| AWS の認証 | OIDC で `AWS_DEPLOY_ROLE_ARN` のロールを引き受ける | - |
| zip のアップロード | `s3://$ARTIFACT_BUCKET/ticketqr/{impl}/{sha}-{試行回数}/` に置く（接頭辞を毎回変えるので、Lambda のコードが必ず更新される） | {impl}/DEPLOY.md 4-A.1（zip のアップロード） |
| API のスタック | `api.yaml` を `ticketqr-{impl}` にデプロイし、`ApiUrl` を取り出す | {impl}/DEPLOY.md 4-A.1（スタックのデプロイ） |
| Web のスタック | `web.yaml` を `ticketqr-web-{impl}` にデプロイし（`ApiBaseUrl` を渡す）、バケット・ディストリビューション・URL を取り出す | web/DEPLOY.md 3章 |
| CORS | API Gateway の CORS に SPA のオリジンを入れる（暫定。`api.yaml` に CORS の設定が入るまで） | web/DEPLOY.md 5章 |
| SPA のアップロード | `config.json`（`apiBaseUrl` と `modes`）を作り、`dist` と一緒に S3 に置いて、CloudFront のキャッシュを消す | web/DEPLOY.md 6章 |
| スモークテスト | SPA と `config.json` が取れること、SPA のオリジンからの発行に CORS のヘッダーが付くこと、QR 画像 API が PNG を返すこと。URL はジョブのサマリーに出す | {impl}/DEPLOY.md 7章、web/DEPLOY.md 7章 |

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
| 解析サーバーのスタブ（Rust・Node）のビルドとデプロイ | CI に入れていない |

## 5. ローカルでの確認

ワークフローを GitHub に push する前に、手元で確かめる。

```sh
# 構文と、よくある誤りの検査
go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
actionlint .github/workflows/*.yml

# CI を Docker の中で実行する（nektos/act）
go install github.com/nektos/act@v0.2.89
act workflow_dispatch -W .github/workflows/st-ci.yml --bind \
  --artifact-server-path /tmp/act-artifacts \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

- `--bind` は、作業ディレクトリをコンテナにそのままマウントする（E2E のジョブの中の `docker compose` が、ホストのパスでファイルをマウントするため）。そのため、ジョブの中の `npm ci` が、ホストの `node_modules` を Linux 用のもので上書きする。`node_modules` を含まないコピーで実行するとよい
- **act の制約**: act に内蔵された成果物のサーバーは、`actions/upload-artifact@v7` / `download-artifact@v8` のプロトコルに対応していない（`Failed to CreateArtifact: Unexpected end of JSON input` になる）。ローカルで流すときは、コピーしたワークフローの中だけ、この2つを `@v4` に置き換える（リポジトリのワークフローは最新版のまま）
  ```sh
  sed -i '' 's#upload-artifact@v7#upload-artifact@v4#; s#download-artifact@v8#download-artifact@v4#' .github/workflows/st-ci.yml
  ```
- Apple シリコンの Mac では `--container-architecture linux/arm64` を付ける（Lambda 用の zip は arm64 用なので、どちらでも同じものができる）
- デプロイのワークフローは、AWS の認証が必要なので act では確かめられない
