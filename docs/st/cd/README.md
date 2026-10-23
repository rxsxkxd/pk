# CD パイプライン（CodePipeline / CodeBuild）

master への push で、**単体テスト → E2E → Lambda のコードと SPA のファイルだけのデプロイ** を流すパイプライン。AWS の CodePipeline（V2）と CodeBuild で動かす。

> **状態（2026-10-22）**: テンプレートと手順を作り、手元で確かめられる範囲だけ確かめた（9章）。AWS 上ではまだ作っていない。E2E の段は、何もしない空のビルドを置いてある（6章）。

関連: デプロイを「更新だけ」にする考え方は [UPDATE_ONLY.md](UPDATE_ONLY.md)（このパイプラインはその案を採ったもの）。CodePipeline の構成パターンの比較は [PATTERNS.md](PATTERNS.md) 0章。GitHub Actions の CI（pull request ごとの単体テスト）は [../ci/README.md](../ci/README.md)。GitHub Actions からデプロイする旧案は [GITHUB_ACTIONS.md](GITHUB_ACTIONS.md)。

## 1. 全体像

```
GitHub（このリポジトリ。master への push）
  └─ CodeConnections（GitHub との接続。AWS 側で管理）
       └─ CodePipeline V2: ticketqr-st（実行は順番待ち QUEUED。デプロイが重ならない）
            ├─ Source  そのコミットのソース
            ├─ Test    CodeBuild ticketqr-st-test    単体テスト（Go・SPA）→ Lambda の zip と SPA の dist を作る
            ├─ E2E     CodeBuild ticketqr-st-e2e     今は何もしない（6章）
            └─ Deploy  CodeBuild ticketqr-st-deploy  zip と SPA のファイルを差し替える（4章）
```

| 方針 | 内容 |
|---|---|
| ビルドは 1 回だけ | Test の段で作った zip と `dist` を、E2E・Deploy の段にそのまま渡す。Deploy の段ではビルドしない |
| デプロイは更新だけ | 差し替えるのは Lambda のコードと SPA のファイルだけ。CloudFormation のスタック、`config.json`、Parameter Store、IAM には触れない（構築は手順書で行う。UPDATE_ONLY.md 1・2章） |
| 権限を分ける | Test・E2E の CodeBuild は AWS の資源に触れない（ログとパイプラインの成果物だけ）。デプロイの権限は Deploy の CodeBuild だけが持ち、その中身も差し替えに要るものだけ（8章） |
| GitHub に AWS の権限を置かない | パイプラインは AWS 側から GitHub を読む（CodeConnections）。GitHub Actions には AWS の権限も秘密情報も渡さない |
| 実装は Go だけ | Node.js 版はパイプラインに入れない |

## 2. ファイル

| ファイル | 内容 |
|---|---|
| `cd/pipeline.yaml` | パイプライン、CodeBuild のプロジェクト 3 つ、ロール 3 つ、段の間の受け渡し用のバケット、ログ。構築は [../infra/CD_PIPELINE.md](../infra/CD_PIPELINE.md) |
| `cd/buildspec/test.yml` | Test の段（3章） |
| `cd/buildspec/e2e.yml` | E2E の段（何もしない。6章） |
| `cd/buildspec/deploy.yml` | Deploy の段。`cd/deploy.sh` を呼ぶだけ |
| `cd/deploy.sh` | 差し替えの本体（4章）。手元でも同じものを流せる |
| `cd/UPDATE_ONLY.md` | デプロイを更新だけにする考え方（このパイプラインが採った案） |
| `cd/PATTERNS.md` | CI / CD の構成パターンの比較と、CodePipeline でスタックも更新する案（検討の記録） |
| `cd/GITHUB_ACTIONS.md`、`cd/github-actions/deploy.yml` | GitHub Actions からデプロイする旧案（採用していない。今の CI では動かない） |

buildspec はリポジトリの中にあるので、手順はコミットごとに固定される（パイプラインの設定を変えなくても、buildspec を直して push すれば次の実行から変わる）。

## 3. Test の段（単体テストとビルド）

| 順 | コマンド | 内容 |
|---|---|---|
| 1 | `npm --prefix web ci` | SPA の依存を入れる |
| 2 | `make -C go test` | `go vet` と Go の単体テスト |
| 3 | `make -C go build` | Lambda 用の zip（arm64）。使うのは `go/bin/ticketqr.zip` |
| 4 | `npm --prefix web run format:check` | Prettier |
| 5 | `npm --prefix web test` | Vitest |
| 6 | `npm --prefix web run build` | 型チェックと SPA のビルド。発行方式は CodeBuild の環境変数 `GRANT_MODE`（`pipeline.yaml` の `GrantMode`。既定 `page`） |

- 単体テストは外に通信しない。画像解析サーバーは偽物（Go の `stubVerifier`）か、テストの中で立てるローカルのサーバー（`httptest`）、SPA の `fetch` は `vi.stubGlobal` で差し替えている。外への通信を止めた状態で全件通ることを確かめた（2026-10-22。macOS の `sandbox-exec`）
- 外に出るのは、依存の取得（`npm ci`、Go のモジュール）と、次の Go 本体の取得だけ
- 環境: CodeBuild の ARM のイメージ `aws/codebuild/amazonlinux-aarch64-standard:4.0`。Node.js は 24、Go は 1.26 まで入っている。`go.mod` の `go` 行（今は 1.27.3）がそれより新しいので、`GOTOOLCHAIN=auto` で go コマンドに Go 本体を取らせる（チェックサムで検証される）。イメージに `go.mod` の版が入ったら、`runtime-versions` を上げて `GOTOOLCHAIN` を外せる（[MAINTENANCE.md](../MAINTENANCE.md)）
- 次の段に渡すもの: `go/bin/ticketqr.zip`、`web/dist/`、`cd/`（Deploy の段のスクリプト）

## 4. Deploy の段（差し替えだけ）

`cd/deploy.sh` が次の順に行う。

| 順 | やること | コマンド |
|---|---|---|
| 1 | zip を控えの場所と、スタックが指す場所に置く | `aws s3 cp` → `s3://<成果物バケット>/ticketqr/go/releases/<コミット>/ticketqr.zip` と `…/current/ticketqr.zip` |
| 2 | 2 つの関数のコードを差し替え、反映を待つ | `aws lambda update-function-code`（`current` の zip）、`aws lambda wait function-updated` |
| 3 | SPA の控えを置く（ロールバック用） | `aws s3 sync web/dist/ s3://<成果物バケット>/ticketqr/go/web-releases/<コミット>/`（`config.json` を除く） |
| 4 | SPA の `assets/*` を上げ、古いものを消す | `aws s3 sync … --delete`（`index.html` と `config.json` を除く。1 年キャッシュ） |
| 5 | `index.html` を最後に上げる | `aws s3 cp`（`no-cache`）。古い `index.html` が、まだない `assets/*` を指すことがない順番 |
| 6 | CloudFront のキャッシュを消す | `aws cloudfront create-invalidation --paths /index.html` |
| 7 | スモークテスト（`WEB_URL` を入れたときだけ） | 画面と `config.json` が 200 で返ること |

- `config.json`（環境ごとの設定）は上げない・消さない。Web のスタックを作ったときに置いたものを使い続ける（web/DEPLOY.md 6章）
- スモークテストでは発行しない（解析サーバーを呼ばない）。発行まで確かめるのは aws-test/PLAN.md の A
- API のスタックの `ArtifactPrefix` は `ticketqr/go/current` にしておく（[../infra/CD_PIPELINE.md](../infra/CD_PIPELINE.md) 2章の 3）。こうすると、あとで構築の手順でスタックを更新しても、今動いているコードのまま変わらない（UPDATE_ONLY.md 3.1）
- SAM（infra/sam）で作った環境でも使える（関数名を `pipeline.yaml` のパラメータで渡す）。ただし、その後に `sam deploy` をすると、SAM がビルドしたコードに置き換わる

## 5. 構築（初回だけ）

パイプラインのスタック（`cd/pipeline.yaml`）の作成、GitHub との接続、API のスタックを `current` の zip に向ける作業は、最初の環境構築の手順として [../infra/CD_PIPELINE.md](../infra/CD_PIPELINE.md) にまとめている。

## 6. E2E の段（今は空）

`cd/buildspec/e2e.yml` は、メッセージを出して成功するだけ。段の場所と CodeBuild のプロジェクトは先に作っておき、中身はあとで入れる。

入れるときの候補と注意:

| 項目 | 内容 |
|---|---|
| A: 今の compose の E2E を CodeBuild で流す | CodeBuild のプロジェクトを特権モード（`PrivilegedMode: true`）にして、`docker compose -f compose.e2e.yaml up --build ...` を流す（E2E_RUN.md 2章）。Test の段の `web/dist` を使えるが、compose は API をソースから作り直す（E2E.md 2.3）ので、入力にはソースも要る（`pipeline.yaml` の E2E の段の入力に `SourceOutput` を足す） |
| A の注意 | 毎回、golang・node・Playwright・Garage のイメージを取得する（合わせて数 GB）。Docker Hub は取得の回数に上限があり、CodeBuild の共有の IP では上限に当たりやすい。ECR Public のミラー（`public.ecr.aws/docker/library/golang` など）に替えるか、ECR のプルスルーキャッシュを使う |
| B: デプロイしたあとに、本物の環境に対して流す | Deploy の段のあとに段を足し、Playwright のテストを本物の CloudFront・API Gateway に対して流す（PATTERNS.md 0.5 の E2） |

## 7. ロールバック

前の版の控えを使う。ビルドし直さなくてよい。

```sh
SHA=<戻したいコミット>
P=ticketqr/go
# Lambda
aws s3 cp "s3://$ARTIFACT_BUCKET/$P/releases/$SHA/ticketqr.zip" "s3://$ARTIFACT_BUCKET/$P/current/ticketqr.zip"
for fn in ticketqr-go-tickets ticketqr-go-get-qr; do
  aws lambda update-function-code --function-name "$fn" --s3-bucket "$ARTIFACT_BUCKET" --s3-key "$P/current/ticketqr.zip"
  aws lambda wait function-updated --function-name "$fn"
done
# SPA
aws s3 sync "s3://$ARTIFACT_BUCKET/$P/web-releases/$SHA/" "s3://$WEB_BUCKET/" --delete \
  --exclude index.html --exclude config.json --cache-control 'public, max-age=31536000, immutable'
aws s3 cp "s3://$ARTIFACT_BUCKET/$P/web-releases/$SHA/index.html" "s3://$WEB_BUCKET/index.html" \
  --cache-control no-cache --content-type 'text/html; charset=utf-8'
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths /index.html
```

戻したあとの master への push で、パイプラインはまた最新のコミットを出す。直すまで出したくないときは、パイプラインの段の移行を止める（`aws codepipeline disable-stage-transition --pipeline-name ticketqr-st --stage-name Deploy --transition-type Inbound --reason ...`）。

## 8. 権限

ロールは 3 つ（パイプライン、Test・E2E、Deploy）。Deploy の CodeBuild だけが差し替えの権限を持つ。中身は [../infra/CD_PIPELINE.md](../infra/CD_PIPELINE.md) 4章。

## 9. 確かめたこと（2026-10-22。手元だけ）

| 順 | 確かめたこと | 結果 |
|---|---|---|
| 1 | `pipeline.yaml` の cfn-lint（SAM CLI に入っている 1.53.3） | エラーなし |
| 2 | buildspec 3 つが YAML として読めること | 読めた |
| 3 | `cd/deploy.sh` の shellcheck | 指摘なし |
| 4 | `cd/deploy.sh` を、`aws` と `curl` を記録するだけの偽物に差し替えて流す | 4章の順にコマンドが出た。設定が足りないとき・zip がないときは、何もせずに止まった |
| 5 | Test の段のコマンド（`npm ci` を除く）を手元で流す | Go のテスト・zip、Prettier、Vitest（115 件）、SPA のビルドがすべて成功 |
| 6 | 単体テストが外に通信しないこと | 外への通信を止めて、Go と SPA のテストが全件成功（3章） |

確かめていないこと（[OPEN_ITEMS.md](../OPEN_ITEMS.md) 1章）: AWS 上でのスタックの作成と実行、CodeBuild の上で `GOTOOLCHAIN=auto` が Go 1.27.3 を取れること、CodeConnections の接続、Deploy の段の権限が足りること。
