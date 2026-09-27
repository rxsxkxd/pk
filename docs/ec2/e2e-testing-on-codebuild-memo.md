# メモ: CodeBuild での E2E テストの構成

> 位置付け: 選択肢と検討事項を忘れないための備忘メモ。**E2E は任意の工程で、現時点では導入・構成を確定していない。** 関連する本体は [Rails アプリのリリース検証・AMI 化・起動テンプレート更新の自動化](./ami-build-pipeline.md)（リリース検証のパイプラインで任意に実行する想定）。

## 一般的な 2 つの構成

| 構成 | 内容 | 確認できる範囲 |
|---|---|---|
| **A. デプロイ済み環境を外からテスト** | アプリはリリース用インスタンス（またはステージング）で稼働させ、CodeBuild からブラウザで URL を操作する。Playwright が主流（ほかに Cypress、Selenium、Capybara で外部 URL を操作する方法） | nginx・Passenger・設定・DB 接続を含む**実環境**での動作 |
| B. CodeBuild 内でアプリも起動 | CodeBuild 内で Rails と DB を起動し、Rails の system spec（Capybara + headless Chrome）を実行する。いわゆる CI での E2E | アプリのコードとしての動作。実環境や AMI の中身は確認できない |

- B はプルリクエストごとの CI として一般的。ただし CodeBuild には DB 用のサービスコンテナがないため、Docker（特権モード）やテスト用 RDS で DB を用意する手間がある。
- **リリースするものを実環境で確認する目的には A が合う。**

## 構成 A を採る場合の概要

```
リリース検証パイプライン
 ├─ リリース処理: SSM でリリース用インスタンスにチェックアウト、RSpec、起動
 └─ E2E（任意）: CodeBuild（VPC 内）→ http://<リリース用インスタンス>/ を Playwright で操作
      └─ 成功したら後続（AMI 作成パイプライン）へ
```

- **ネットワーク**: CodeBuild をリリース用インスタンスと同じ VPC のプライベートサブネットに配置。インスタンスのセキュリティグループで CodeBuild のセキュリティグループからの 80 番を許可。VPC 内の CodeBuild がインターネット（npm・ブラウザ取得）に出るには NAT ゲートウェイが必要。接続先はプライベート IP の固定か、Route 53 プライベートホストゾーンの名前で指定。
- **テストコード**: アプリと同じリポジトリ（例: `e2e/`）に置き、同じタグをチェックアウトしてバージョンを揃える。
- **ブラウザ**: Playwright 公式 Docker イメージをビルド環境に使う（起動が速く安定）か、標準イメージで `npx playwright install --with-deps chromium`。
- **結果**: JUnit 形式で出力して CodeBuild のテストレポートで閲覧。失敗時のスクリーンショット・動画・トレースは成果物として S3 に保存。
- **AMI への影響がない**: 外から実行するため、Chrome やテストツールがリリース用インスタンス（＝ AMI）に入らない。インスタンス上で system spec を動かす方式との大きな違い。

buildspec の骨子:

```yaml
version: 0.2
phases:
  install:
    commands:
      - cd e2e && npm ci
      - npx playwright install --with-deps chromium
  build:
    commands:
      - cd e2e && BASE_URL="http://release.myapp.internal" npx playwright test --reporter=junit,html
reports:
  e2e:
    files: [e2e/results/junit.xml]
    file-format: JUNITXML
artifacts:
  files:
    - e2e/playwright-report/**/*
    - e2e/test-results/**/*
```

## 導入時に決めること

- **テストデータ**: RSpec 用とは別の E2E 用 DB（またはステージング DB）を使い、実行前に seed を入れ直すなどして毎回同じ状態から始める。本番 DB には向けない。
- **ログイン情報**: テスト用アカウントの認証情報は Secrets Manager から取得する。
- **不安定なテスト対策**: 再試行は 1〜2 回、失敗時は必ずトレースを残す。対象は重要な操作の流れ（ログイン、主要画面、登録処理など）に絞り、画面の細部は RSpec に任せる。
- **実行時間**: 増えてきたら Playwright のシャーディングや CodeBuild のバッチビルドで並列化する。
- **任意にする方法**: パイプライン変数（例: `RUN_E2E`）で E2E のアクションの実行を切り替える。「スモーク（数本）は毎回、全体は必要なときだけ」という分け方もある。

## その他の選択肢

- **Ruby で統一**: Capybara + Cuprite（または Selenium）で `Capybara.app_host` をリリース用インスタンスの URL にし、`run_server = false` にすれば、RSpec のまま構成 A を組める。チームが Ruby 中心なら有力。
- **インスタンス上で system spec を実行**: 構成は単純だが Chrome が AMI（本番）に含まれるため、優先度は低い。
- **本番反映後の定期確認**: CloudWatch Synthetics（Canary）で主要な流れを定期実行する。リリース前の E2E とは役割が異なり、併用が一般的。
