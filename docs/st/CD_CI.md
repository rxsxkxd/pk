# CI / CD 構成案（CI は GitHub Actions、CD は CodePipeline / CodeBuild）

> **状態**: 構成案（未実装）。CI は今の `.github/workflows/st-ci.yml`（[CI.md](CI.md) 3章）をそのまま使い、デプロイを GitHub Actions（`st-deploy.yml`。CI.md 4章、未検証）から **AWS CodePipeline / CodeBuild** に移す。デプロイの中身（コマンド）は、各手順書（[go/DEPLOY.md](go/DEPLOY.md)・[node/DEPLOY.md](node/DEPLOY.md)・[web/DEPLOY.md](web/DEPLOY.md)）の CloudFormation の手順と同じにする。
>
> どの構成パターンを採るかは未決定（0章で比較）。1〜9章は、そのうちパターン P1 の詳細。P3 を採る場合の差分は 0.4 にまとめた。

## 0. 目的と構成パターンの評価

### 0.1 目的

| 目的 | 内容 |
|---|---|
| E2E は GitHub Actions で行う | 今の `st-ci.yml`（compose で storage + api + e2e）をそのまま使う |
| デプロイの認証・許可の設定は、なるべく AWS 側に一元化する | デプロイに使う権限、承認、実行の記録は AWS（CodePipeline / CodeBuild / IAM）で管理する。GitHub 側に AWS の権限や秘密情報をなるべく置かない |

この2つを両立するには、「GitHub Actions の E2E が通った」ことを AWS 側に伝える方法と、デプロイするパッケージをどちらで作るかを決める必要がある。

### 0.2 構成パターン

| # | パターン | GitHub → AWS の受け渡し | パッケージを作る場所 | GitHub 側に置くもの |
|---|---|---|---|---|
| **P1** | GitHub Actions が S3 に置き、パイプラインを開始する（1〜9章の詳細） | OIDC で権限の小さいロールを引き受け、S3 にリリースを置いて `StartPipelineExecution` | CI（1回だけ） | ロールの ARN（秘密ではない）と、S3 への書き込み・パイプラインの開始の権限 |
| P2 | GitHub Actions が S3 に置くだけ。パイプラインは S3 のイベントで開始 | OIDC で S3 に置く。EventBridge がパイプラインを開始 | CI（1回だけ） | ロールの ARN と、S3 への書き込みの権限だけ |
| **P3** | GitHub Actions は E2E のあとに **Git のタグを付けるだけ**。パイプラインはタグで開始し、CodeBuild がパッケージを作り直す | なし（タグの push。CodePipeline が CodeConnections で GitHub を見ている） | **CD（CodeBuild で作り直す）** | **AWS の権限は何もない**（タグを付けるための GitHub 内の権限だけ） |
| P4 | パイプラインは master への push で開始し、CodeBuild が GitHub Actions の結果を問い合わせて、成功していれば先に進む | なし（AWS 側から GitHub の API に問い合わせる） | CD | なし。ただし AWS 側に GitHub のトークン（長期の秘密情報）が要る |
| P5 | CodePipeline が起点で、GitHub Actions の E2E を呼び出して、結果を待つ | なし（AWS 側から GitHub の API で起動・待ち合わせ） | CD（または GitHub Actions から S3 に置く） | なし。AWS 側に GitHub のトークンが要る |
| P6 | GitHub Actions のジョブを、CodeBuild が管理するランナーの上で動かし、デプロイもそのジョブで行う | なし（ランナーが CodeBuild の IAM ロールで動く） | CI | なし（CodeConnections で接続） |
| 参考 | 今の `st-deploy.yml`（GitHub Actions が OIDC でデプロイ用のロールを引き受け、直接デプロイする） | OIDC で強い権限のロール | CI | デプロイの強い権限 |

### 0.3 評価

◎ とても合う ○ 合う △ 条件付き × 合わない

| 観点 | P1 | P2 | **P3** | P4 | P5 | P6 | 参考 |
|---|---|---|---|---|---|---|---|
| 認証・許可の AWS 側への一元化 | ○（信頼ポリシーと権限は AWS 側。ただし GitHub が S3 に書ける） | ○（同左。権限は1つ） | **◎（GitHub は AWS に何もできない。接続の許可も AWS 側の CodeConnections）** | △（AWS 側に GitHub のトークンを置く） | △（同左） | ○（IAM ロールは AWS 側。ただしデプロイの流れは GitHub 側） | × |
| GitHub 側の権限・秘密情報 | ロールの ARN と小さい権限 | ロールの ARN と S3 だけ | **なし** | なし | なし | なし | 強い権限 |
| AWS 側の秘密情報 | なし | なし | **なし** | GitHub のトークン | GitHub のトークン | なし | なし |
| テストしたものと同じものを出すか（ビルドの回数） | **◎（1回。ハッシュで照合できる）** | ◎ | △（2回。ツールの版を固定し、同じコミットから作る。単体テストも流し直せる） | △ | △〜◎ | ◎ | ◎ |
| E2E の結果との結び付き | ◎（成功したときだけ置く） | ◎ | ◎（成功したときだけタグを付ける。タグの作成を保護する） | ○（問い合わせて確かめる） | ◎ | ◎ | ◎ |
| 構成の単純さ | ○（OIDC のロール1つ） | △（EventBridge の設定が増える） | **○（タグの保護と CodeConnections。自作の処理なし）** | ×（問い合わせと待ち合わせを自作） | ×（起動と待ち合わせを自作） | △（ランナーの設定。CodePipeline を使わない） | ◎ |
| 承認・実行の記録の場所 | AWS | AWS | **AWS** | AWS | AWS | GitHub | GitHub |
| ビルドの依存（npm など）と強い権限の分離 | ◎（ビルドは GitHub、デプロイは AWS） | ◎ | ○（パッケージ用とデプロイ用の CodeBuild のロールを分ける） | ○（同左） | ○ | △ | △ |
| 目的（CodeBuild / CodePipeline でデプロイ）に合うか | ◎ | ◎ | ◎ | ◎ | ◎ | ×（CodePipeline を使わない） | × |

### 0.4 推奨

目的の「認証・許可を AWS 側に一元化」を最も重視するなら **P3**、「テストしたものと同じファイルを出す」ことを最も重視するなら **P1** が最適。どちらも自作の処理（GitHub の API の呼び出しや待ち合わせ）がなく、構成は単純。P4・P5 は AWS 側に GitHub のトークンが要り、自作の処理も増えるので勧めない。

**今回の目的に合わせた推奨: P3（タグで開始し、CodeBuild でパッケージを作り直す）。**

- GitHub 側には AWS の権限も秘密情報も置かない。CodePipeline と GitHub の接続（CodeConnections）は、AWS のコンソールで一度許可するだけで、権限・承認・記録はすべて AWS 側に集まる
- E2E を通ったコミットにだけタグが付くので、テストに落ちたものは反映されない
- 弱点の「ビルドが2回」は、次の対策で小さくする: ツールの版を CI と同じに固定する（`go/go.mod` の Go の版、`.node-version` などの Node の版、`package-lock.json`）、パッケージを作る CodeBuild でも単体テストを流す、パッケージ用（権限なし）とデプロイ用（デプロイの権限）で CodeBuild のプロジェクトとロールを分ける

P3 の構成（P1 の詳細との差分）:

```
GitHub Actions（st-ci.yml）: テスト・ビルド・E2E
  └─ release-tag（master の push で、すべて成功したとき）: タグ st-release/<run 番号> を付けて push（GITHUB_TOKEN。AWS の認証なし）

AWS: CodePipeline V2 ticketqr-st（トリガー: CodeConnections で、タグ st-release/* の push）
  ├─ Source    GitHub のそのタグのコミット（CodeConnections）
  ├─ Package   CodeBuild ticketqr-st-package（デプロイの権限なし）: 単体テスト → Go・Node の zip と SPA の dist を作る
  ├─ Dev       CodeBuild ticketqr-st-deploy（デプロイの権限あり）×2 並列（Go・Node）: 反映 → スモークテスト（4.2 と同じ）
  ├─ Approve   手動の承認（本番がある場合）
  └─ Prod      Dev と同じ（本番の設定）
```

| 項目 | P3 での内容 |
|---|---|
| GitHub Actions の追加 | ジョブ `release-tag`: `needs` に全ジョブ、`permissions: contents: write`。`git tag st-release/$GITHUB_RUN_NUMBER && git push origin st-release/$GITHUB_RUN_NUMBER` |
| タグの保護 | GitHub のリポジトリのルールセットで、`st-release/*` の作成・削除・付け替えを制限する（GitHub Actions 以外が作れないようにする。設定できる範囲は実装時に確かめる） |
| CodePipeline のトリガー | V2 のトリガー（Git の push、タグ `st-release/*`）。GitHub Actions の `GITHUB_TOKEN` で付けたタグでも、CodeConnections（GitHub App）には通知が届く想定（実装時に確かめる） |
| AWS 側の一度だけの設定 | CodeConnections の接続を作り、GitHub 側で GitHub App のインストールを承認する（対象はこのリポジトリだけ） |
| パッケージ用の CodeBuild | Go・Node のビルド環境（版は CI と同じ）。`make -C go test build`、`npm --prefix node ci/test/run build`、`npm --prefix web ci/test/run build`。出力は zip と `dist`。IAM の権限は、ログとパイプラインの成果物バケットだけ |
| デプロイ用の CodeBuild | 4.2 と同じ（入力が Package の出力になるだけ。ハッシュの照合はパイプラインの中なので不要） |
| GitHub Actions のロール・リリースバケット | 不要（P1 の 3章・5章の公開用ロールとリリースバケットはなくなる） |

### 0.5 E2E をどこで行うか: GitHub Actions 上の模擬環境か、AWS 上の本物に近い環境か

| # | 方式 | 内容 |
|---|---|---|
| E1 | GitHub Actions 上の模擬環境だけ（今） | compose で storage（Garage）・api（Lambda の RIE + 自作のゲートウェイ）・e2e（Playwright）を動かす（E2E.md） |
| E2 | AWS 上の本物に近い環境だけ | パイプラインで Dev（または E2E 専用の環境）にデプロイしたあと、CodeBuild から同じ Playwright のテストを、本物の CloudFront・API Gateway・Lambda に対して流す |
| **E3** | **両方（段階を分ける）** | PR と master では E1 で早く確かめる。パイプラインでは Dev への反映のあとに E2 を流し、通ったものだけを本番の承認に進める |

評価（◎ とても良い ○ 良い △ 条件付き × 悪い）:

| 観点 | E1: GitHub Actions の模擬環境 | E2: AWS の本物に近い環境 | E3: 両方 |
|---|---|---|---|
| 本番との近さ | △: API Gateway（ルート・CORS の設定・スロットリング・6MB の上限・エラーの応答）、CloudFront（CSP などのヘッダー・キャッシュ・OAC）、Parameter Store、HTTPS（Client Hints は HTTPS でしか届かない）、コールドスタートは確かめられない（E2E.md 8章） | ◎: これらをすべて本物で確かめられる | ◎ |
| 確かめられること（今のテスト） | 3つの発行方式、エラー、リロード、形式、CSRF（`web` と `evil` の2つのオリジン） | 同じテスト。ただし CSRF のテストには、攻撃者を想定した2つ目のオリジン（別の CloudFront か S3 のサイト）を AWS に用意する必要がある | 両方 |
| 結果が出るまでの速さ | ◎: 数分。PR ごとに流せる | △: デプロイ（CloudFormation、CloudFront の反映）を待つので十数分 | ○: PR は E1 で早く、本番の前は E2 で確実に |
| PR での確認 | ◎: AWS に触らずに、どの PR でも流せる（フォークからの PR でも） | △: PR ごとに環境を作るか、共有の環境を順番に使う必要がある。フォークからの PR には AWS の権限を渡せない | ◎（PR は E1） |
| 認証・権限（0.1 の目的） | ◎: AWS の権限が要らない | ◎: CodeBuild の IAM ロールで動く。権限は AWS 側だけ | ◎ |
| 費用 | ◎: GitHub Actions の時間だけ | ○: CodeBuild の時間と、テストのたびの発行（Lambda・画像解析サーバーの呼び出し） | ○ |
| 安定性 | ○: 外部に依存しない。ただし模擬の部品（Garage、自作のゲートウェイ）の不具合がテストの失敗に見えることがある | ○: 本物なので模擬の差はない。ただし CloudFront の反映待ちやコールドスタートで、待ち時間の調整が要る | ○ |
| 保守 | △: 模擬の部品（Garage の設定、ゲートウェイ、Dockerfile）を保守し続ける | ○: テストの宛先を変えるだけ。模擬の部品は要らない | △（両方を保守する） |
| 環境の汚れ・後片付け | ◎: 毎回作って消す | △: 共有の Dev にテストのデータ（発行のログ）が残る。E2E 専用の環境を分けると片付けやすい | △ |
| 画像解析サーバー | モック（`ANALYZER_MODE=mock`） | `mock` か、スタブ（`http`）か、本物 | 段階ごとに選べる |

**推奨: E3（両方。段階を分ける）。**

- E1 は「コードが壊れていないか」を PR ごとに早く・安く確かめる門番として残す。AWS の権限が要らないので、0.1 の目的にも反しない
- E2 は「本番と同じ部品で動くか」を、本番の承認の前に確かめる。API Gateway の CORS の設定や CloudFront の CSP のように、**模擬環境では原理的に確かめられないもの**は、ここでしか見つからない
- E2 は CodeBuild で動くので、AWS への権限は AWS 側だけで完結する（0.4 の P3 とよく合う）
- どちらか1つだけにするなら: 開発の速さと費用を優先するなら E1、本番での不具合を減らすことを優先するなら E2。ただし E2 だけだと PR の時点で確かめられず、マージしてから不具合に気づくことになる

E3 にした場合のパイプライン（0.4 の P3 に1段足す）:

```
GitHub Actions: 単体テスト → E1（模擬環境の E2E）→ タグ
CodePipeline:  Source → Package → Dev（反映 + スモークテスト）→ E2E（CodeBuild で E2 を Dev に対して）→ Approve → Prod
```

E2 のために必要な変更:

| 変更 | 内容 |
|---|---|
| テストの宛先 | `e2e/env.ts` は `WEB_URL`・`API_URL` を環境変数で変えられる。CodeBuild から、Dev の CloudFront と API Gateway の URL を渡す |
| SPA の配置 | 本物の環境ではパイプラインが SPA を置くので、`global-setup.ts` の S3（Garage）への配置を飛ばす設定を足す（例: `SKIP_DEPLOY=1`） |
| CSRF のテスト（ケース9） | 攻撃者を想定した2つ目のオリジンを AWS に置く（E2E 専用の小さな S3 + CloudFront）。用意するまでは、E2 ではこのケースを飛ばす |
| CodeBuild の環境 | Playwright と Chromium が入ったイメージ（Playwright の公式イメージを ECR に写したもの）か、標準のイメージに `npx playwright install --with-deps chromium` |
| 失敗したときの記録 | Playwright のレポートとトレースを、CodeBuild の成果物（S3）に残す |
| 環境 | まずは Dev に対して流す。テストのデータを本番に近い環境に残したくなければ、E2E 専用の環境（スタック）を分ける |

## 1. 方針と役割分担（P1 の詳細。ここから 9章まで）

| 役割 | 担当 | やること |
|---|---|---|
| **CI** | GitHub Actions | テスト、ビルド（Lambda の zip、SPA の `dist`）、E2E。master の CI が通ったら、成果物を1つの「リリース」にまとめて AWS に渡す |
| **CD** | CodePipeline / CodeBuild | リリースを受け取り、**再パッケージ**（環境ごとの配置と設定。下の表）をして、Lambda（API のスタック）と Web（S3 + CloudFront）に反映する。動作確認（スモークテスト）と、本番の前の承認もここで行う |

「再パッケージ」の意味（この案での定義）:

| する | しない |
|---|---|
| リリースの中の zip を、成果物バケットに**デプロイごとの接頭辞**で置き直す（CloudFormation が Lambda のコードを更新できるようにする） | Go・Node のコンパイルやバンドルのやり直し（**ビルドは CI で1回だけ**。テストと E2E を通ったものと同じバイナリを反映する） |
| 環境ごとの値（API の URL、`config.json` の `modes`、CORS のオリジン）を入れる | |
| スタックのパラメータを環境ごとに決めて、CloudFormation でデプロイする | |

方針:

- **ビルドは1回だけ**: CI で作ってテストした zip を、そのまま CD で反映する（CD でビルドし直すと、テストしていないものを出すことになる）
- **成果物は検証してから反映する**: CodeBuild は、リリースの中身のハッシュ（と、本番では来歴の証明）を確かめてから反映する（9.3）
- **起動は GitHub Actions から AWS への一方向**: GitHub Actions の最後に、OIDC の一時的な認証情報で CodePipeline を開始する（2.1）。AWS 側に GitHub のトークンは置かない
- **GitHub に AWS の強い権限を持たせない**: GitHub Actions のロールは「リリースを置いて、パイプラインを開始する」だけ。デプロイの権限は CodeBuild だけが持つ
- **デプロイの記録と承認は AWS 側に集める**: パイプラインの実行履歴、承認、ロールバックは CodePipeline で行う
- **手順書と同じコマンド**: CodeBuild の buildspec は、各手順書の CloudFormation の手順（go/node DEPLOY.md 4.2・4.3、web/DEPLOY.md 3・5・6章）を実行する

## 2. 全体の流れ

```
GitHub（master への push / PR）
  └─ GitHub Actions: st-ci.yml
       ├─ go / node / web / infra（テスト・ビルド）
       ├─ e2e（compose。matrix: go / node）
       └─ publish（master の push だけ。上がすべて成功したとき）
            ├─ OIDC で「公開用ロール」を引き受ける（S3 への書き込みと、パイプラインの開始だけ）
            ├─ リリースの zip を S3 に置く: s3://ticketqr-releases-…/st/release.zip（バージョニングあり）
            └─ CodePipeline を開始する（変数 ReleaseSha = コミットの SHA）

AWS
  └─ CodePipeline（V2）: ticketqr-st
       ├─ Source       S3 の st/release.zip（開始した時点の最新のバージョン）
       ├─ Dev          CodeBuild ×2 を並列: Go 版・Node 版をそれぞれ再パッケージ → デプロイ → スモークテスト
       ├─ Approve      手動の承認（SNS で通知。本番がある場合だけ）
       └─ Prod         Dev と同じ CodeBuild を、本番の設定で実行
```

### 2.1 起動の向き: GitHub Actions の最後に CodePipeline を呼ぶ（P1 の場合）

CI と CD のつなぎ方は、どちらから呼ぶかで2通りある。**GitHub Actions の最後に、AWS の一時的な認証情報（OIDC）で CodePipeline を呼ぶ方が、構成が少なく、秘密情報も要らない**ので、P1 ではこちらを採る。認証を AWS に一元化する目的では、GitHub に AWS の権限を持たせない P3（タグで開始）の方が合う（0章）。

| | X: CodePipeline から GitHub Actions を呼ぶ | **Y: GitHub Actions の最後に CodePipeline を呼ぶ（P1 で採る）** |
|---|---|---|
| 起点 | CodePipeline（GitHub からソースを取得して開始） | GitHub Actions（master の CI が成功したら開始） |
| GitHub Actions を動かす方法 | CodePipeline には GitHub Actions を呼ぶ標準のアクションがない。Lambda か CodeBuild から GitHub の API（`workflow_dispatch`）を呼ぶ処理を自作する | - |
| 結果の待ち合わせ | GitHub Actions の完了を、GitHub の API で繰り返し確かめる処理を自作する | 不要（CI が終わってから CD が始まる） |
| 成果物の受け渡し | GitHub の API で成果物を取りに行くか、結局 GitHub Actions から S3 に置く（＝ Y と同じ AWS の認証も必要になる） | GitHub Actions が S3 に置く |
| 認証 | **両方向**: AWS → GitHub（GitHub のトークンか GitHub App の鍵を Secrets Manager に置く。長期の秘密情報）と、多くの場合 GitHub → AWS も | **一方向だけ**: GitHub → AWS（OIDC。一時的な認証情報で、秘密情報はない） |
| 作るもの | パイプライン、CodeConnections（GitHub との接続）、起動と待ち合わせの Lambda / CodeBuild、トークンの管理 | パイプライン、OIDC のロール1つ、`publish` ジョブ |
| 実行の記録 | CodePipeline に集まる | CI は GitHub、CD は CodePipeline。変数 `ReleaseSha`（コミットの SHA）で対応が分かる |

Y で用意するもの（これだけで動く）:

| 場所 | 用意するもの |
|---|---|
| GitHub | `st-ci.yml` の `publish` ジョブ（3.1）、environment `release`、変数 `AWS_REGION`・`AWS_PUBLISH_ROLE_ARN`・`RELEASE_BUCKET` |
| AWS | GitHub の OIDC プロバイダー、公開用ロール（権限は `s3:PutObject` と `codepipeline:StartPipelineExecution` の2つだけ）、リリースバケット、パイプライン（Source は S3 で、変更の検知はしない）、CodeBuild プロジェクト |

さらに単純にする候補と、採らない理由:

| 候補 | 内容 | 採らない理由 |
|---|---|---|
| S3 への配置だけで、パイプラインを自動で開始する | 公開用ロールの権限を `s3:PutObject` だけにし、S3 のイベント（EventBridge）でパイプラインを開始する | 権限は1つ減るが、AWS 側に EventBridge のルール（構成によっては CloudTrail も）が要り、構成は増える。どのコミットかを変数で渡せなくなる |
| GitHub Actions の `publish` ジョブを CodeBuild の上で動かす（CodeBuild のマネージドな GitHub Actions ランナー） | ジョブが CodeBuild の IAM ロールで動くので、OIDC が要らない | CodeBuild のランナーと GitHub との接続（CodeConnections）の設定が要り、OIDC のロール1つより手間が多い |

## 3. GitHub Actions（CI と、リリースの受け渡し）

### 3.1 追加するジョブ: `publish`（`st-ci.yml`）

| 項目 | 内容 |
|---|---|
| 条件 | master への push で、`go`・`node`・`web`・`infra`・`e2e` がすべて成功したとき（PR では動かない） |
| 権限 | `id-token: write`（OIDC）。GitHub の environment `release`（任意で承認者を付けられる） |
| やること | 各ジョブの成果物（`lambda-go`、`lambda-node`、`web-dist`）とテンプレートを、1つの zip（リリース）にまとめて S3 に置き、パイプラインを開始する |

```yaml
  publish:
    needs: [go, node, web, infra, e2e]
    if: github.event_name == 'push' && github.ref == 'refs/heads/master'
    runs-on: ubuntu-latest
    environment: release
    permissions: { contents: read, id-token: write, attestations: write }
    steps:
      - uses: actions/checkout@v7
      - uses: actions/download-artifact@v8
        with: { path: release/artifacts }        # lambda-go / lambda-node / web-dist
      - name: Assemble the release
        run: |
          mkdir -p release/infra release/testdata release/buildspec
          cp -r docs/st/infra/cloudformation release/infra/
          cp docs/st/testdata/images/photo.jpg release/testdata/
          cp docs/st/cd/buildspec/*.yml release/buildspec/
          printf '{"sha":"%s","ref":"%s","run":"%s"}\n' "$GITHUB_SHA" "$GITHUB_REF" "$GITHUB_RUN_ID" > release/manifest.json
          (cd release && find artifacts -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)   # 中身の改ざんの検知用（9.3）
          (cd release && zip -qr ../release.zip .)
      # （任意）GitHub のアーティファクト証明: 「このワークフローがこのコミットから作った」ことを署名で残す（9.3）
      - uses: actions/attest-build-provenance@v3
        with: { subject-path: release.zip }
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.AWS_PUBLISH_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
      - name: Upload and start the pipeline
        run: |
          aws s3 cp release.zip "s3://${{ vars.RELEASE_BUCKET }}/st/releases/$GITHUB_SHA.zip"   # 記録用（消さない）
          aws s3 cp release.zip "s3://${{ vars.RELEASE_BUCKET }}/st/release.zip"                # パイプラインが読む
          aws codepipeline start-pipeline-execution --name ticketqr-st \
            --variables name=ReleaseSha,value=$GITHUB_SHA
```

### 3.2 リリースの zip の中身

```
release.zip
├── manifest.json                 # コミットの SHA、ブランチ、GitHub Actions の実行 ID
├── SHA256SUMS                    # artifacts/ の各ファイルのハッシュ（CodeBuild が照合する）
├── artifacts/
│   ├── lambda-go/{ticketqr.zip,exampleqr.zip}
│   ├── lambda-node/{ticketqr.zip,exampleqr.zip}
│   └── web-dist/                 # SPA のビルド結果（config.json は環境ごとに作り直す）
├── infra/cloudformation/{api.yaml,example.yaml,web.yaml}
├── buildspec/{deploy.yml}        # CodeBuild の手順（リポジトリの docs/st/cd/buildspec/ から）
└── testdata/photo.jpg            # スモークテスト用
```

- buildspec もリリースに入れる: 手順とテンプレートとコードの組み合わせが、コミットごとに固定される
- `st/releases/<SHA>.zip` は消さずに残す（どのコミットでも、もう一度デプロイできる）

### 3.3 今の `st-deploy.yml` との関係

この案を採用したら、`st-deploy.yml`（GitHub Actions から直接デプロイする。未検証）は廃止する。CI.md 4章の「デプロイ用の IAM ロール」も、権限の小さい「公開用ロール」（5章）に置き換わる。

## 4. CodePipeline / CodeBuild（CD）

### 4.1 パイプライン `ticketqr-st`（CodePipeline V2）

| ステージ | アクション | 内容 |
|---|---|---|
| Source | S3（`st/release.zip`） | 開始した時点の最新のバージョンを取り出す。変更の検知はしない（`PollForSourceChanges: false`。GitHub Actions が開始する） |
| Dev | CodeBuild `ticketqr-st-deploy` を2つ並列（`IMPL=go`、`IMPL=node`。`DEPLOY_ENV=dev`） | 再パッケージ → API のスタック → Web のスタック → CORS → SPA のアップロード → スモークテスト（4.2） |
| Approve | 手動の承認 | 本番を作るときだけ。SNS で通知し、`manifest.json` のコミットを確かめてから承認する |
| Prod | Dev と同じ CodeBuild（`DEPLOY_ENV=prod`） | Dev と同じ手順を、本番の設定で実行する |

- 実装（Go・Node）ごとにスタックが分かれているので、並列に動かしても干渉しない
- 片方の実装だけを使う環境では、使わない側のアクションを外す
- パイプラインの変数 `ReleaseSha` で、どのコミットを反映しているかが実行履歴に残る

### 4.2 CodeBuild プロジェクト `ticketqr-st-deploy`

| 項目 | 内容 |
|---|---|
| 環境 | Amazon Linux の ARM（`aws/codebuild/amazonlinux-aarch64-standard`）。使うのは AWS CLI と `curl`、`python3` だけで、ビルドのツール（Go・Node のコンパイラー）は要らない |
| 入力 | Source の成果物（リリースの zip を展開したもの） |
| 環境変数 | `IMPL`（`go` / `node`）、`DEPLOY_ENV`（`dev` / `prod`）、`ARTIFACT_BUCKET`、`WEB_MODES`（`config.json` の `modes`。既定 `["page"]`） |
| buildspec | リリースの中の `buildspec/deploy.yml` |

`buildspec/deploy.yml`（案。コマンドは各手順書と同じ）:

```yaml
version: 0.2
env:
  shell: bash
phases:
  pre_build:
    commands:
      - sha256sum -c SHA256SUMS --quiet   # CI が作ったものから変わっていないことを確かめる（9.3）
      - SHA=$(python3 -c 'import json;print(json.load(open("manifest.json"))["sha"])')
      - export ARTIFACT_PREFIX=ticketqr/$IMPL/$SHA-$CODEBUILD_BUILD_NUMBER
      - export SALT_PARAM=/ticketqr/$IMPL/signing-salt
  build:
    commands:
      # 再パッケージ: zip をデプロイごとの接頭辞で置く（go/node DEPLOY.md 4.2）
      - aws s3 cp artifacts/lambda-$IMPL/ticketqr.zip  s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX/ticketqr.zip
      - aws s3 cp artifacts/lambda-$IMPL/exampleqr.zip s3://$ARTIFACT_BUCKET/$ARTIFACT_PREFIX/exampleqr.zip
      # API のスタック（go/node DEPLOY.md 4.3）
      - >-
        aws cloudformation deploy --stack-name ticketqr-$IMPL --template-file infra/cloudformation/api.yaml
        --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset
        --parameter-overrides Impl=$IMPL ArtifactBucket=$ARTIFACT_BUCKET ArtifactPrefix=$ARTIFACT_PREFIX SigningSaltParameterName=$SALT_PARAM
      - export API_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-$IMPL --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
      # Web のスタック（web/DEPLOY.md 3章）
      - >-
        aws cloudformation deploy --stack-name ticketqr-web-$IMPL --template-file infra/cloudformation/web.yaml
        --no-fail-on-empty-changeset --parameter-overrides ApiBaseUrl=$API_URL
      - export WEB_BUCKET=$(aws cloudformation describe-stacks --stack-name ticketqr-web-$IMPL --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)
      - export DIST_ID=$(aws cloudformation describe-stacks --stack-name ticketqr-web-$IMPL --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" --output text)
      - export WEB_URL=$(aws cloudformation describe-stacks --stack-name ticketqr-web-$IMPL --query "Stacks[0].Outputs[?OutputKey=='WebUrl'].OutputValue" --output text)
      # API の CORS（web/DEPLOY.md 5章。api.yaml に CORS が入るまでの暫定）
      - API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='ticketqr-$IMPL'].ApiId | [0]" --output text)
      - >-
        aws apigatewayv2 update-api --api-id $API_ID
        --cors-configuration "{\"AllowOrigins\":[\"$WEB_URL\"],\"AllowMethods\":[\"GET\",\"POST\"],\"MaxAge\":300}"
      # SPA と環境ごとの config.json（web/DEPLOY.md 6章）
      - |
        printf '{ "apiBaseUrl": "%s", "modes": %s }\n' "$API_URL" "${WEB_MODES:-[\"page\"]}" > config.json
      - aws s3 sync artifacts/web-dist/ s3://$WEB_BUCKET/ --delete --exclude index.html --exclude config.json --cache-control 'public, max-age=31536000, immutable'
      - aws s3 cp artifacts/web-dist/index.html s3://$WEB_BUCKET/index.html --cache-control no-cache --content-type 'text/html; charset=utf-8'
      - aws s3 cp config.json s3://$WEB_BUCKET/config.json --cache-control no-cache --content-type application/json
      - aws cloudfront create-invalidation --distribution-id $DIST_ID --paths /index.html /config.json
  post_build:
    commands:
      # スモークテスト（go/node DEPLOY.md 8章、web/DEPLOY.md 7章）。build が失敗したときは飛ばす
      - '[ "$CODEBUILD_BUILD_SUCCEEDING" = 1 ] || exit 1'
      - curl -fsS -o /dev/null "$WEB_URL/"
      - |
        curl -fsS -D headers.txt -o ticket.json -H "Origin: $WEB_URL" -H 'Accept: application/json' -F image=@testdata/photo.jpg "$API_URL/v1/tickets"
        grep -i "^access-control-allow-origin: $WEB_URL" headers.txt
      - QR_URL=$(python3 -c 'import json;print(json.load(open("ticket.json"))["qrUrl"])')
      - test "$(curl -fsS -o /dev/null -w '%{content_type}' "$QR_URL")" = image/png
```

## 5. 権限（IAM）

| ロール | 使うもの | 権限 |
|---|---|---|
| 公開用ロール（GitHub OIDC） | GitHub Actions の `publish` | `s3:PutObject`（リリースバケットの `st/*`）、`codepipeline:StartPipelineExecution`（`ticketqr-st` だけ）。信頼ポリシーは `repo:rxsxkxd/pk:environment:release` に限る。リリースバケットは、このロール以外の書き込みをバケットポリシーで拒否する（9.3） |
| CodePipeline のサービスロール | パイプライン | リリースバケットの読み取り、パイプラインの成果物バケットの読み書き、CodeBuild の開始、SNS への通知 |
| CodeBuild のサービスロール | `ticketqr-st-deploy` | CI.md 4.2 のデプロイ用ロールと同じ範囲（CloudFormation、Lambda の実行ロールの作成と `iam:PassRole`、Lambda、API Gateway、ログ、成果物バケットと Web のバケット、CloudFront）。対象は `ticketqr-*` に限る |
| （任意）CloudFormation の実行ロール | スタック | CodeBuild のロールから強い IAM の権限を外したいときに、`--role-arn` で CloudFormation に渡す |

- 長期のアクセスキーは、どこにも置かない
- salt と API キーは、これまでどおり Parameter Store に事前に作っておく（パイプラインは読まない。Lambda が実行時に読む）

## 6. パイプライン自体の構築

パイプラインと関連するリソースは、API・Web とは別のテンプレート `infra/cloudformation/pipeline.yaml`（新規。スタック `ticketqr-st-pipeline`）で作る。最初に一度だけ手で作り、その後の変更もこのテンプレートで行う。

| リソース | 内容 |
|---|---|
| リリースバケット | `ticketqr-releases-{account}-{region}`。非公開、バージョニングあり、古いバージョンはライフサイクルで消す（例: 90日） |
| パイプラインの成果物バケット | CodePipeline がステージ間の受け渡しに使う。非公開 |
| GitHub の OIDC プロバイダーと公開用ロール | 5章 |
| CodeBuild プロジェクト | `ticketqr-st-deploy`（4.2） |
| CodePipeline | `ticketqr-st`（V2。4.1） |
| SNS トピック | 承認の依頼と、失敗の通知 |

成果物バケット（../DEPLOY.md 2章）、salt、画像解析サーバーのスタブは、今までどおりパイプラインの外で管理する。

## 7. ロールバックと失敗したとき

| 状況 | 動き・対応 |
|---|---|
| CloudFormation の更新が失敗 | スタックが自動で元に戻る。パイプラインはそのステージで止まる |
| スモークテストが失敗 | パイプラインが止まり、本番には進まない。Dev は直前の状態ではなく新しい版のまま残るので、下のどちらかで戻す |
| 前の版に戻す | CodePipeline V2 のステージのロールバック（前に成功した実行の成果物でやり直す）、または `st/releases/<SHA>.zip` を `st/release.zip` に置き直してパイプラインを開始する |
| CodeBuild のログ | CloudWatch Logs（`/aws/codebuild/ticketqr-st-deploy`）。どのコマンドで失敗したかが分かる |

## 8. 運用

- **通知**: パイプラインの失敗と承認の依頼を SNS で受け取る（メール、または Slack などへの転送）
- **費用**: CodePipeline V2 はアクションの実行時間、CodeBuild はビルドの時間に応じた従量課金。デプロイ1回あたり数分の見込み（実装時に見積もる）
- **どのコミットが動いているか**: パイプラインの実行履歴（変数 `ReleaseSha`）と、各環境の `manifest.json`（必要なら SPA と一緒に置く）で分かる

## 9. パッケージを CI で作るか、CD で作り直すか（ベストプラクティス）

### 9.1 2つの方式

| | A: CI で作って S3 に置き、CD は反映するだけ（この案） | B: CD（CodeBuild）がソースから作り直す |
|---|---|---|
| 流れ | GitHub Actions がビルド・テスト・E2E → zip を S3 へ → CodePipeline が反映 | CodePipeline が GitHub からソースを取得（CodeConnections）→ CodeBuild がビルド → 反映 |
| ビルドの回数 | 1回 | 2回（CI と CD） |
| テストしたものとデプロイするものの一致 | **同じファイル**（ハッシュで確かめられる） | 同じソースからの別のビルド。ツールの版やベースイメージが違えば、中身がずれうる（Go・Node のビルドを完全に再現できるようにしない限り、保証できない） |
| CI の結果との結び付き | CI が成功したときだけ、CI が S3 に置く | CodePipeline は GitHub Actions の結果を知らない。テストに落ちたコミットでもデプロイが動きうる（別途、結果を確かめる仕組みが要る） |
| GitHub → AWS の認証 | GitHub Actions が **OIDC** で、権限の小さいロール（S3 への書き込みとパイプラインの開始だけ）を引き受ける | GitHub に AWS の権限は渡さない。AWS 側が **GitHub App（CodeConnections）** でリポジトリを読む |
| 長期の秘密情報 | なし（OIDC は一時的な認証情報。ロールの ARN は秘密ではない） | なし（接続は AWS 側で管理） |
| 必要なビルド環境 | GitHub Actions だけ | GitHub Actions と CodeBuild の両方に、Go・Node・SPA のビルド環境を用意して、版をそろえ続ける |
| 主な攻撃の入口 | S3 のリリースを書き換えられること（9.3 で防ぐ） | GitHub のリポジトリへの書き込み（A と同じ）。CodeBuild の中でビルドするので、ビルドの依存（npm など）が CD の権限の中で動く |

### 9.2 ベストプラクティスの整理

| 原則 | 内容 | A | B |
|---|---|---|---|
| **一度だけビルドし、同じものを環境に昇格させる**（build once, deploy many） | dev で確かめたものと同じファイルを prod に出す。12-Factor の「ビルド・リリース・実行の分離」、SLSA の考え方でも推奨される | ◎ | △（毎回ビルドし直す） |
| **長期の秘密情報を CI に置かない** | GitHub Actions には OIDC で一時的な認証情報を渡す。アクセスキーは使わない | ◎ | ◎ |
| **最小権限** | CI のロールは「成果物を置く」まで。デプロイの権限（IAM のロールの作成など、強いもの）は AWS の中の CD だけが持つ | ◎ | ◎ |
| **信頼の範囲を絞る** | OIDC の信頼ポリシーで、リポジトリ・ブランチ・environment を限定する（`sub` を `repo:rxsxkxd/pk:environment:release` に。`aud` は `sts.amazonaws.com`） | ◎ | -（OIDC を使わない） |
| **成果物の完全性を確かめる** | CD は、受け取ったものが CI の作ったものから変わっていないことを確かめてから反映する（ハッシュ、署名、来歴の証明） | ○（9.3 を足して ◎） | -（自分で作るので不要。代わりにソースの取得元を信頼する） |
| **本番の前の承認を、コードを書く人と別の仕組みで行う** | GitHub が乗っ取られても本番に出ないよう、承認は AWS 側（CodePipeline の手動承認）で行う | ◎ | ◎ |
| **ビルドの依存を、強い権限の中で動かさない** | npm の依存などは、デプロイの権限がない環境でビルド・テストする | ◎（ビルドは権限の小さい GitHub Actions） | △（CodeBuild の中でビルドする。ビルド用とデプロイ用のプロジェクトとロールを分ければ緩和できる） |

**この観点での結論: A（CI で作って S3 に置き、CD は検証してから反映する）が最も一般的な推奨に合う。** ただし「認証・許可を AWS 側に一元化する」目的を優先する場合は、B に近い P3（0章）を選ぶ。そのときは、ツールの版の固定、パッケージ用の CodeBuild での単体テスト、パッケージ用とデプロイ用のロールの分離で、B の弱点を小さくする。 一般的な推奨（一度だけビルドして昇格、OIDC、最小権限、AWS 側での承認）にすべて合う。A の弱点である「S3 の成果物の書き換え」は、9.3 の対策で防ぐ。

### 9.3 A を安全にするための対策

| 対策 | 内容 | この案での扱い |
|---|---|---|
| OIDC の信頼ポリシーを絞る | `sub` を environment `release` に限定し、その environment は master だけ・（任意で）承認者付きにする。PR やフォークのワークフローからは引き受けられない | 必須 |
| リリースバケットに書けるのは公開用ロールだけ | バケットポリシーで、公開用ロール以外の `PutObject` を拒否する。バージョニングで、上書きされても前の版が残る | 必須 |
| ハッシュの照合 | CI が `SHA256SUMS` を作ってリリースに入れ、CodeBuild が `sha256sum -c` で照合してから反映する（4.2 の buildspec） | 必須（同じ zip の中にあるので、壊れや入れ違いの検知が主な目的） |
| 来歴の証明（provenance） | GitHub のアーティファクト証明（`actions/attest-build-provenance`）で、「このリポジトリのこのワークフローが、このコミットから作った」ことを署名で残す。CodeBuild で `gh attestation verify release.zip --repo rxsxkxd/pk --signer-workflow …/st-ci.yml` を実行し、合わなければ止める | 推奨（本番を作るとき）。S3 を書き換えられても、署名が合わないので反映されない |
| Lambda のコード署名 | AWS Signer で zip に署名し、Lambda のコード署名の設定（Code Signing Config）で、署名のないコードを拒否する | 任意（本番で、さらに強くしたいとき）。テンプレートの変更が要る |
| 本番の承認 | CodePipeline の手動承認。承認者は `manifest.json` のコミットを確かめる | 本番を作るとき |

## 10. 段階的な進め方

| フェーズ | 内容 |
|---|---|
| 1 | `pipeline.yaml`（リリースバケット、CodeBuild、パイプライン、ロール）と `cd/buildspec/deploy.yml` を作る。Dev のステージだけで動かす |
| 2 | `st-ci.yml` に `publish` ジョブを足し、master への push で Dev に自動で反映されるようにする |
| 3 | `st-deploy.yml` を廃止し、CI.md 4章をこの文書への案内に置き換える |
| 4 | 本番の環境を作り、承認と Prod のステージを足す |
| 5 | example.com の QR のスタックや、画像解析サーバーの `http` モードのパラメータを、必要に応じて buildspec に足す |

## 11. 決めること

1. 構成パターン（0章）: P3（タグで開始し、CodeBuild でパッケージを作り直す。認証を AWS に一元化）か、P1（CI で作って S3 に置く。テストしたものと同じファイルを出す）か（推奨: 目的に合わせて P3）
2. E2E をどこで行うか（0.5）: GitHub Actions の模擬環境（E1）、AWS の本物に近い環境（E2）、両方（E3）（推奨: E3）
3. 本番の環境を、同じ AWS アカウントでスタック名を分けて作るか（例: `ticketqr-prod-go`）、別のアカウントにするか（推奨: 別のアカウント。CodePipeline からアカウントをまたいでデプロイするには、KMS のキーとアカウントをまたぐロールが必要）
4. Dev への反映を、master への push ごとに自動にするか（推奨: 自動）
5. Go 版・Node 版の両方を、毎回デプロイするか（比較の期間は両方。どちらかに決めたら片方にする）
6. 承認者と通知先
7. リリースの記録（`st/releases/<SHA>.zip`）を残す期間

## 12. 参考

- GitHub Docs: Configuring OpenID Connect in Amazon Web Services（GitHub Actions から OIDC で AWS のロールを引き受ける）
- GitHub Docs: Using artifact attestations to establish provenance for builds（`actions/attest-build-provenance`、`gh attestation verify`）
- [SLSA（Supply-chain Levels for Software Artifacts）](https://slsa.dev/)
- [The Twelve-Factor App: V. Build, release, run](https://12factor.net/build-release-run)
- [AWS Lambda: Using code signing to verify code integrity](https://docs.aws.amazon.com/lambda/latest/dg/configuration-codesigning.html)
- AWS CodePipeline: Amazon S3 source actions、CodeConnections（GitHub との接続）
