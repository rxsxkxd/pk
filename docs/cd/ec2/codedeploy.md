# EC2 上の Rails / Go アプリを CodeDeploy で更新する

デプロイ方式は In-place（既存インスタンスを入れ替えず、その場で更新する）を前提とする。

## 全体の流れ

```
[CI (GitHub Actions / CodeBuild など)]
  ビルド (Go: バイナリ / Rails: bundle + assets:precompile)
  → appspec.yml とスクリプトを含めて zip にする → S3 にアップロード
  → aws deploy create-deployment
        ↓
[CodeDeploy] デプロイグループ（EC2 のタグ / ASG で指定）
        ↓
[EC2 上の CodeDeploy エージェント]
  S3 から取得 → appspec.yml の hooks を順に実行
  ApplicationStop → BeforeInstall → Install → AfterInstall → ApplicationStart → ValidateService
```

---

## 1. 事前ビルドは必要か

**必須ではない。** CodeDeploy に必要なのは「ルートに `appspec.yml` があるリビジョン（ファイル一式）」を、CodeDeploy が取りに行ける場所に置くことだけ。ビルドするかどうかは自由。ただし CodeDeploy 自身にはビルド機能がないため、ビルドが要るなら CI 側か EC2 上のどちらかで行う。

### リビジョンを置ける場所

| 置き場所 | 形式 | 補足 |
|---|---|---|
| S3 | zip / tar / tgz | 一般的なやり方。CI でアップロードする |
| GitHub | リポジトリのコミット | `--github-location repository=org/repo,commitId=xxxx` で直接デプロイできる。アップロードは不要（GitHub との接続設定は必要） |

### ビルドをどこでやるかの選択肢

**A. 事前にビルドする（CodeBuild / GitHub Actions など）→ 推奨**

- Go：バイナリだけを配る
- Rails：`bundle install` と `assets:precompile` を済ませたものを配る
- 利点：
  - EC2 にコンパイラや Node などのビルドツールが要らない
  - デプロイが速い
  - どの台にも同じ成果物が入る
  - ロールバックは前回の成果物を配り直すだけで済む

**B. ソースをそのまま配り、EC2 上の hooks でビルドする**

```bash
# AfterInstall の例
# Go
cd /opt/goapp && go build -o bin/server ./cmd/server

# Rails
cd /var/www/railsapp && bundle install && bin/rails assets:precompile
```

- 利点：CI が要らない。GitHub から直接デプロイすれば最小構成で済む
- 欠点：
  - EC2 に Go / Ruby のビルド環境や Node などが必要
  - デプロイ中に CPU やメモリを食い、サービスに影響が出る
  - 台ごとにビルドするので時間がかかり、gem のダウンロードなど外部依存の失敗リスクも台数分増える

### Rails と Go での実情

- **Go**：EC2 に Go の環境を入れるのは無駄が多いので、事前ビルドが事実上の標準。
- **Rails**：インタプリタ言語なので、ソースを配って EC2 上で `bundle install` する B の運用もよくある。中間案として「`assets:precompile` だけ CI で行い、`bundle install` は EC2 で行う」構成もある。ネイティブ拡張の gem で CI と EC2 の環境差が問題になる場合に使う。

本番運用では **A（事前ビルドして S3 に置く）** を推奨。小規模な環境や検証なら B（GitHub から直接デプロイして EC2 上でビルド）でも動く。

---

## 2. 事前準備（初回のみ）

### IAM

| ロール | 付ける先 | 権限 |
|---|---|---|
| CodeDeploy サービスロール | CodeDeploy | マネージドポリシー `AWSCodeDeployRole` |
| インスタンスプロファイル | EC2 | アーティファクト用 S3 バケットの `s3:GetObject` と `s3:ListBucket`、`AmazonSSMManagedInstanceCore`（推奨） |
| CI 用ロール（GitHub OIDC） | GitHub Actions | `s3:PutObject`、`codedeploy:CreateDeployment` / `GetDeployment*` / `RegisterApplicationRevision` / `GetApplicationRevision` |

### EC2 に CodeDeploy エージェントを入れる（Amazon Linux 2023 の例）

```bash
sudo dnf install -y ruby wget
cd /tmp
wget https://aws-codedeploy-ap-northeast-1.s3.ap-northeast-1.amazonaws.com/latest/install
chmod +x ./install && sudo ./install auto
sudo systemctl enable --now codedeploy-agent
```

SSM の Distributor パッケージ `AWSCodeDeployAgent` を使って一括で入れることもできる。

### アプリ本体は systemd で管理する

CodeDeploy は「ファイルを配置してスクリプトを実行する」だけのサービス。プロセスの起動・停止は systemd に任せるのが定石。

```ini
# /etc/systemd/system/goapp.service
[Unit]
Description=Go app
After=network.target

[Service]
User=app
WorkingDirectory=/opt/goapp
EnvironmentFile=/etc/goapp/env
ExecStart=/opt/goapp/bin/server
Restart=always

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/puma.service
[Unit]
Description=Puma (Rails)
After=network.target

[Service]
User=app
WorkingDirectory=/var/www/railsapp
EnvironmentFile=/etc/railsapp/env
ExecStart=/bin/bash -lc 'bundle exec puma -C config/puma.rb'
Restart=always

[Install]
WantedBy=multi-user.target
```

### CodeDeploy のアプリケーションとデプロイグループを作る

```bash
aws deploy create-application --application-name goapp --compute-platform Server

aws deploy create-deployment-group \
  --application-name goapp \
  --deployment-group-name goapp-prod \
  --service-role-arn arn:aws:iam::123456789012:role/CodeDeployServiceRole \
  --ec2-tag-filters Key=App,Value=goapp,Type=KEY_AND_VALUE \
  --deployment-config-name CodeDeployDefault.OneAtATime \
  --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE \
  --load-balancer-info targetGroupInfoList=[{name=goapp-tg}] \
  --deployment-style deploymentType=IN_PLACE,deploymentOption=WITH_TRAFFIC_CONTROL
```

- ALB の下にある場合は `WITH_TRAFFIC_CONTROL` を指定する。インスタンスをターゲットグループから外してから更新し、更新後に戻すので、無停止で1台ずつ入れ替えられる。
- ASG を使う場合は `--auto-scaling-groups` を指定する。

---

## 3. Go アプリの場合

### リポジトリの構成

```
appspec.yml
scripts/
  stop.sh
  after_install.sh
  start.sh
  validate.sh
```

### appspec.yml

```yaml
version: 0.0
os: linux
files:
  - source: bin/server
    destination: /opt/goapp/bin
file_exists_behavior: OVERWRITE
permissions:
  - object: /opt/goapp
    owner: app
    group: app
hooks:
  ApplicationStop:
    - location: scripts/stop.sh
      timeout: 60
      runas: root
  AfterInstall:
    - location: scripts/after_install.sh
      timeout: 60
      runas: root
  ApplicationStart:
    - location: scripts/start.sh
      timeout: 60
      runas: root
  ValidateService:
    - location: scripts/validate.sh
      timeout: 120
      runas: root
```

### スクリプト

```bash
# scripts/stop.sh
#!/bin/bash
set -eu
systemctl stop goapp || true   # 初回はサービスがないので失敗させない
```

```bash
# scripts/after_install.sh
#!/bin/bash
set -eu
chmod +x /opt/goapp/bin/server
```

```bash
# scripts/start.sh
#!/bin/bash
set -eu
systemctl daemon-reload
systemctl start goapp
```

```bash
# scripts/validate.sh
#!/bin/bash
set -eu
for i in $(seq 1 30); do
  curl -fsS http://localhost:8080/healthz && exit 0
  sleep 2
done
exit 1
```

### ビルドとパッケージ（CI）

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o bin/server ./cmd/server   # Graviton の場合は arm64
zip -r goapp-${GITHUB_SHA}.zip appspec.yml scripts bin
```

---

## 4. Rails アプリの場合

Go よりひと手間増える。ポイントは次の3つ。

- `bundle install` と `assets:precompile` は、なるべく CI 側で済ませておく（EC2 の負荷と所要時間を減らすため）
- `db:migrate` は1台だけで実行する
- `log/`、`tmp/`、`storage/` は配置先の外（共有ディレクトリ）に置く

### appspec.yml

```yaml
version: 0.0
os: linux
files:
  - source: /
    destination: /var/www/railsapp
file_exists_behavior: OVERWRITE
permissions:
  - object: /var/www/railsapp
    owner: app
    group: app
hooks:
  ApplicationStop:
    - location: scripts/stop.sh
      timeout: 120
      runas: root
  AfterInstall:
    - location: scripts/after_install.sh
      timeout: 900
      runas: app
  ApplicationStart:
    - location: scripts/start.sh
      timeout: 120
      runas: root
  ValidateService:
    - location: scripts/validate.sh
      timeout: 180
      runas: root
```

### スクリプト

```bash
# scripts/after_install.sh  (runas: app)
#!/bin/bash
set -eu
cd /var/www/railsapp
set -a; source /etc/railsapp/env; set +a     # RAILS_ENV, DATABASE_URL, RAILS_MASTER_KEY など

# 共有ディレクトリへのシンボリックリンク
for d in log tmp storage; do
  rm -rf "$d"; ln -sfn /var/www/shared/$d "$d"
done

bundle config set --local deployment true
bundle config set --local without 'development test'
bundle install --jobs 4

# CI で precompile 済みなら不要
# bundle exec rails assets:precompile

# migrate は代表の1台だけで実行する（後述）
if [ "${RUN_MIGRATION:-false}" = "true" ]; then
  bundle exec rails db:migrate
fi
```

```bash
# scripts/stop.sh
#!/bin/bash
systemctl stop puma || true
```

```bash
# scripts/start.sh
#!/bin/bash
set -eu
systemctl daemon-reload
systemctl start puma
# Sidekiq がある場合: systemctl restart sidekiq
```

`scripts/validate.sh` は Go と同様に、`/up`（Rails 7.1+）や `/healthz` を curl で確認する。

### マイグレーションの扱い（どれか1つを選ぶ）

1. **CI から先に実行する（推奨）**：デプロイ前に SSM Run Command で1台に `rails db:migrate` を実行させてから、`create-deployment` を呼ぶ
2. 移行用のデプロイグループ（1台だけ、`RUN_MIGRATION=true` を設定）を先にデプロイし、その後に本番グループをデプロイする
3. 台数が1台だけなら、after_install.sh でそのまま実行してもよい

いずれの場合も、旧コードと新スキーマが共存する時間ができる。カラムの削除やリネームは2段階に分けて行うなど、後方互換を意識したマイグレーションにする。

### シークレット

`/etc/railsapp/env` は、Parameter Store や Secrets Manager から生成するのが安全。たとえば after_install で `aws ssm get-parameters-by-path` を呼んで書き出す。

---

## 5. GitHub Actions からデプロイする例

```yaml
name: deploy
on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.23' }
      - run: CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o bin/server ./cmd/server

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-deploy
          aws-region: ap-northeast-1

      - name: Package & upload
        run: |
          zip -r app.zip appspec.yml scripts bin
          aws s3 cp app.zip s3://my-deploy-bucket/goapp/${GITHUB_SHA}.zip

      - name: Deploy
        run: |
          ID=$(aws deploy create-deployment \
            --application-name goapp \
            --deployment-group-name goapp-prod \
            --s3-location bucket=my-deploy-bucket,key=goapp/${GITHUB_SHA}.zip,bundleType=zip \
            --description "${GITHUB_SHA}" \
            --query deploymentId --output text)
          aws deploy wait deployment-successful --deployment-id "$ID"
```

Rails の場合は、build ステップを `ruby/setup-ruby` + `bundle install` + `rails assets:precompile` に置き換える。ネイティブ拡張の gem があるときは、CI と EC2 で OS とアーキテクチャを揃える必要がある。揃えられない場合は、`bundle install` だけを EC2 側で実行する。

GitHub から直接デプロイする場合（S3 を使わない場合）は、`--s3-location` の代わりに次を指定する。

```bash
--github-location repository=org/repo,commitId=${GITHUB_SHA}
```

---

## 6. 複数台を逐次更新で無停止更新する

**ALB と CodeDeploy のトラフィック制御を組み合わせる**のが基本。CodeDeploy が「1台ずつ ALB から外す → 更新 → 正常になったら戻す」を繰り返す。

### 6.1 仕組み：ALB 連携時のライフサイクル

デプロイグループにターゲットグループを紐づけると、各インスタンスで次の順に処理が進む。

```
BeforeBlockTraffic
BlockTraffic        ← ターゲットグループから登録解除（新規リクエストが来なくなる）
                       登録解除の遅延（deregistration delay）の間、処理中リクエストを待つ
AfterBlockTraffic
ApplicationStop     ← 停止（グレースフルシャットダウン）
DownloadBundle → BeforeInstall → Install → AfterInstall
ApplicationStart    ← 起動
ValidateService     ← 自前のヘルスチェック
BeforeAllowTraffic
AllowTraffic        ← ターゲットグループに再登録し、ALB のヘルスチェックで healthy になるまで待つ
AfterAllowTraffic
```

- `BlockTraffic` / `AllowTraffic` は CodeDeploy が自動で行う。スクリプトは書かない（`Before*` / `After*` にはスクリプトを書ける）。
- OneAtATime の場合、1台が `AfterAllowTraffic` まで成功してから次の台に進む。
- どこかの台で失敗するとデプロイは止まり、自動ロールバックが有効なら前のリビジョンでの再デプロイが走る。
- `WITH_TRAFFIC_CONTROL` を使うには、対象インスタンスがそのターゲットグループに登録されている必要がある。

### 6.2 デプロイグループの設定

```bash
aws deploy create-deployment-group \
  --application-name railsapp \
  --deployment-group-name railsapp-prod \
  --service-role-arn arn:aws:iam::123456789012:role/CodeDeployServiceRole \
  --ec2-tag-filters Key=App,Value=railsapp,Type=KEY_AND_VALUE \
  --load-balancer-info targetGroupInfoList=[{name=railsapp-tg}] \
  --deployment-style deploymentType=IN_PLACE,deploymentOption=WITH_TRAFFIC_CONTROL \
  --deployment-config-name CodeDeployDefault.OneAtATime \
  --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE
```

既存のグループを変更する場合は `aws deploy update-deployment-group --current-deployment-group-name ...` を使う。

### 6.3 デプロイ設定（同時に何台まで外してよいか）

| 設定 | 動き |
|---|---|
| `CodeDeployDefault.OneAtATime` | 1台ずつ更新する。いちばん安全 |
| `CodeDeployDefault.HalfAtATime` | 半数ずつ更新する |
| `CodeDeployDefault.AllAtOnce` | 全台を同時に更新する。**停止が発生する** |
| カスタム | healthy に保つ台数・割合を指定する |

台数が多く、1台ずつでは遅すぎる場合はカスタム設定を作る。

```bash
# 常に75%以上を healthy に保つ
aws deploy create-deployment-config \
  --deployment-config-name Keep75Percent \
  --compute-platform Server \
  --minimum-healthy-hosts type=FLEET_PERCENT,value=75

# 常に (全台数 - 2) 台以上を healthy に保つ例（全台数10台なら value=8）
aws deploy create-deployment-config \
  --deployment-config-name Keep8Hosts \
  --compute-platform Server \
  --minimum-healthy-hosts type=HOST_COUNT,value=8
```

- AZ ごとに順番に更新したい場合は `--zonal-config` も指定できる（1つの AZ を更新し終えてから次の AZ に進む）。
- 外す台数を決めるときは、**残りの台数でピーク負荷をさばけるか**を基準にする。2台構成で1台を外すと、残りの1台に全負荷が集中する。

### 6.4 ターゲットグループの設定

**登録解除の遅延（deregistration delay）**

デフォルトは300秒で、1台ごとに最大5分待たされる。リクエストの最大処理時間（長いアップロードなど）に合わせて、30〜60秒程度に下げるのが一般的。

```bash
aws elbv2 modify-target-group-attributes --target-group-arn <arn> \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30
```

**ヘルスチェック**

`AllowTraffic` は ALB のヘルスチェックで healthy になるまで待つ。間隔としきい値が大きいと、その分だけ待ち時間が延びる。

```bash
aws elbv2 modify-target-group --target-group-arn <arn> \
  --health-check-path /healthz \
  --health-check-interval-seconds 10 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2
```

### 6.5 アプリ側：グレースフルシャットダウン

登録解除のあとも処理中のリクエストは残っているので、停止時に処理しきってから終了させる。

**Go**

```go
func main() {
	srv := &http.Server{Addr: ":8080", Handler: newHandler()}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}
```

**Rails（Puma）**

Puma は SIGTERM を受けると、処理中のリクエストを完了してから終了する。待ち時間の上限は `force_shutdown_after` で設定できる。

```ruby
# config/puma.rb
force_shutdown_after 25
```

**systemd**

停止タイムアウトは、アプリのシャットダウン猶予（上の例では25秒）より長くする。

```ini
[Service]
KillSignal=SIGTERM
TimeoutStopSec=30
```

Sidekiq を併用している場合は、`sidekiq -t 25` のようにシャットダウン猶予を指定し、同様に `TimeoutStopSec` をそれより長くする。

**タイムアウトの関係**

```
deregistration delay (30s)  … ALB が処理中リクエストを待つ時間
  ≧ アプリのシャットダウン猶予 (25s)
  < systemd の TimeoutStopSec (30s)
  < appspec の ApplicationStop timeout (60s〜)
```

### 6.6 ValidateService を厳密に書く

`AllowTraffic` の前に、アプリが確実に応答できることを確認する。ここで失敗すれば、壊れたインスタンスにトラフィックが流れないうちにデプロイが止まる。

```bash
#!/bin/bash
# scripts/validate.sh
set -eu
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 http://localhost:8080/healthz; then
    exit 0
  fi
  sleep 2
done
echo "health check failed" >&2
exit 1
```

- ヘルスチェック用のエンドポイントで DB 接続まで確認すると、より安全。Rails 7.1+ の `/up` はアプリの起動しか確認しない（DB には触れない）ので、必要なら独自のエンドポイントを用意する。
- ただし ALB のヘルスチェックに DB 確認を含めると、DB の一時的な障害で全台が unhealthy になる。ALB 用は軽量なもの、ValidateService 用は詳細なもの、と分ける手もある。

### 6.7 新旧バージョンの混在に注意

順番に更新している間は、**旧バージョンと新バージョンが同時に動く**。無停止更新でいちばん事故が起きやすいところ。

| 問題 | 対策 |
|---|---|
| DB スキーマ | 後方互換のあるマイグレーションにする。migrate はデプロイ前に1回だけ実行する |
| Rails のアセット | 下記参照 |
| セッション・キャッシュの形式 | 新旧どちらのバージョンでも読める形式にする。ALB のスティッキーセッションは根本的な対策にならない |
| API の互換性 | フロントエンドや他サービスから見て、新旧の両方が成り立つ仕様にする |
| ジョブキュー | 旧バージョンが積んだジョブを新バージョンが処理する（逆もある）。ジョブ引数の形式を変えるときは互換を保つ |

**DB スキーマ変更の進め方（例：カラムのリネーム）**

1. リリース1：新カラムを追加し、新旧の両カラムに書き込む
2. データを移行する
3. リリース2：読み込みを新カラムに切り替える
4. リリース3：旧カラムを削除する（Rails では先に `ignored_columns` で参照を外す）

**Rails のアセット**

ダイジェスト付きのファイル名（`application-<hash>.js`）は、各インスタンスのローカルディスクにしかない。混在期間中は次の両方向で 404 が起きる。

- 旧インスタンスが返した HTML が参照する旧アセットへのリクエストが、新インスタンスに届く
- 新インスタンスが返した HTML が参照する新アセットへのリクエストが、旧インスタンスに届く

ローカルに旧アセットを残すだけでは前者しか防げない。確実なのは、**アセットを S3 + CloudFront から配信する**方法。

1. CI で `assets:precompile` を実行する
2. `public/assets` を S3 に同期する（`aws s3 sync public/assets s3://my-assets/assets/`。`--delete` は付けず、旧ファイルを残す）
3. その後に CodeDeploy でデプロイする
4. `config.asset_host` に CloudFront のドメインを設定する

古いアセットは S3 のライフサイクルルールなどで、一定期間後に削除する。

### 6.8 Auto Scaling グループを使う場合

```bash
aws deploy update-deployment-group \
  --application-name railsapp \
  --current-deployment-group-name railsapp-prod \
  --auto-scaling-groups railsapp-asg \
  --outdated-instances-strategy UPDATE
```

- デプロイグループに ASG を指定すると、CodeDeploy は ASG にライフサイクルフックを登録し、スケールアウトで起動した台にも最後に成功したリビジョンを入れる。
- デプロイ中にスケールアウトした台には、古いリビジョンが入ることがある。`--outdated-instances-strategy UPDATE` を指定すると、デプロイ完了後にその台へ追加のデプロイが走る。
- デプロイ中のスケールインで更新中の台が消える事故を避けたい場合は、デプロイ前後でスケーリングを一時停止する。
  ```bash
  aws autoscaling suspend-processes --auto-scaling-group-name railsapp-asg \
    --scaling-processes AlarmNotification ScheduledActions AZRebalance
  # デプロイ
  aws autoscaling resume-processes --auto-scaling-group-name railsapp-asg \
    --scaling-processes AlarmNotification ScheduledActions AZRebalance
  ```
- 1台外しても処理能力が足りるように、最小台数に余裕を持たせる。

### 6.9 所要時間の見積もり

1台あたりの所要時間は、おおよそ次の合計になる。

```
登録解除の遅延 (30s)
+ 停止 (〜25s)
+ ダウンロード・配置・AfterInstall (bundle install などで 30s〜数分)
+ 起動 + ValidateService (〜20s)
+ ALB ヘルスチェック (間隔10s × しきい値2 = 20s)
≒ 2〜3分
```

OneAtATime の場合、全体の所要時間は「1台あたりの時間 × 台数」。台数が増えたら、カスタム設定で同時に更新する台数を増やすか、ビルドを CI に寄せて AfterInstall を短くする。

### 6.10 チェックリスト

- [ ] ALB のターゲットグループをデプロイグループに紐づけ、`WITH_TRAFFIC_CONTROL` を指定した
- [ ] `OneAtATime` かカスタムの `minimum-healthy-hosts` を設定した
- [ ] 残りの台数でピーク負荷をさばける
- [ ] 登録解除の遅延を短くした（30〜60秒）
- [ ] ヘルスチェックのパスと間隔を調整した
- [ ] アプリで SIGTERM を受けてグレースフルシャットダウンするようにした
- [ ] タイムアウトの大小関係（登録解除の遅延 ≧ アプリの猶予 < TimeoutStopSec < appspec timeout）が正しい
- [ ] ValidateService で実際に疎通を確認している
- [ ] マイグレーション、アセット、セッション、ジョブが新旧混在でも壊れない
- [ ] 自動ロールバックを有効にした
- [ ] ASG を使う場合、`--outdated-instances-strategy UPDATE` とスケーリング停止を検討した

---

## 7. ハマりやすいポイント

- **ApplicationStop は「前回デプロイしたリビジョン」のスクリプトが実行される。** 壊れた stop.sh をデプロイすると次のデプロイも失敗する。その場合は `--ignore-application-stop-failures` を付けて回避する。
- 配置先に CodeDeploy 管理外のファイルがあると、`file_exists_behavior` の指定がない場合に失敗する。`OVERWRITE` を指定しておくのが無難。
- ログの場所（調査はまずここを見る）：
  - `/var/log/aws/codedeploy-agent/codedeploy-agent.log`
  - `/opt/codedeploy-agent/deployment-root/<group-id>/<deployment-id>/logs/scripts.log`
- フックのスクリプト内では `DEPLOYMENT_ID`、`DEPLOYMENT_GROUP_NAME`、`LIFECYCLE_EVENT` などの環境変数が使える（例：グループ名で処理を分岐する）。
- エージェントは古いリビジョンを溜め込む。`/etc/codedeploy-agent/conf/codedeployagent.yml` の `:max_revisions:` で保持数を絞れる。
- 失敗時に自動ロールバックすると、前回リビジョンを使った「新しいデプロイ」が走る。DB のマイグレーションは元に戻らない点に注意。
