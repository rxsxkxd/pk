# pk

互いに依存しない小さなプロジェクトと調査メモの集まり。

## プロジェクト

| フォルダ | 内容 |
|---|---|
| [`cp/`](cp/README.md) | DB なしの Rails が返す HTML に React を描画し、Capybara + Selenium/Chrome で検証する Docker Compose の最小構成 |
| [`pw/`](pw/README.md) | Go API・Vite + Vue + TypeScript のフロント・Playwright の E2E テストを別コンテナで動かす Docker Compose 構成 |
| [`lim/`](lim/README.md) | S3 の画像の上半分にガウスぼかしをかけて別の階層へ保存する Go の Lambda（AWS SAM） |
| `bin/` | macOS 用 Todo アプリのビルド済みバイナリ（`Todo.zip`、ソースはここにない） |
| `awsf/` | 空のフォルダ |
| [`docs/st/`](docs/st/README.md) | 画像を外部の解析サーバーで検証し、チケットコードの QR を発行する API（Go / Lambda）と Vue の SPA、インフラ・CI/CD・E2E 一式 |
| [`docs/rds_mysql_upgrade/`](docs/rds_mysql_upgrade/README.md) | RDS for MySQL 8.0 → 8.4 を Blue/Green Deployments で移行する手順書・Go のスクリプト・CI 定義一式 |
| [`docs/ec2/`](docs/ec2/README.md) | Rails アプリのリリース用 EC2 から AMI と起動テンプレートを作り、本番インスタンスを構築する仕組みと設計 |
| [`docs/seq/`](docs/seq/README.md) | Lambda・EC2・ECS・CodeBuild を棚卸しして JSONL で出すツール群（シェル / Ruby / Python の 3 実装） |
| [`docs/rr/`](docs/rr/DESIGN.md) | Rails 5 / Ruby 2.7 を Debian 13 で動かすための設計と Dockerfile の雛形（Ruby のベースイメージとアプリのイメージ） |
| [`docs/app/integrated-management-system/`](docs/app/integrated-management-system/README.md) | テナント横断で DB を JOIN する統合管理システム（Rails 5）の整理と置き換えの検討メモ |
| [`docs/app/tenant-scoped-system-replacement/`](docs/app/tenant-scoped-system-replacement/README.md) | テナントを 1 つ指定して使うシステムの置き換えの検討メモ |
| [`docs/an/rails-table-search/`](docs/an/rails-table-search/README.md) | CSV に並べた複数の Rails プロジェクトの `db/` から、指定したテーブル名を検索するシェルスクリプト |
| `docs/dsnet/` | VPC 構成パターン（EC2 / ECS / VPC 内 Lambda）の概念図と、VPC・SG・NACL・RDS を AWS CLI で一覧する方法のメモ |
| `docs/cd/ec2/` | EC2 上の Rails / Go アプリを CodeDeploy（In-place）で更新する方法のメモ |
| `docs/rails/` | Rails 4.2 → 7.0 のアップグレードで必要な変更・修正の一覧 |

## 単体のメモ

| ファイル | 内容 |
|---|---|
| [`voice-navigation-architecture.md`](voice-navigation-architecture.md) | 音声入力で画面遷移を自動化する構成案 |
| [`whisper-runtime-survey.md`](whisper-runtime-survey.md) | Whisper のローカル推論ランタイム（CTranslate2 / faster-whisper / whisper.cpp）の調査 |
| [`docs/aws-cli-config-inventory.md`](docs/aws-cli-config-inventory.md) | AWS CLI で各サービスの設定を一覧・取得するコマンド集 |
| [`docs/aws-service-connect-lattice-rds-proxy.md`](docs/aws-service-connect-lattice-rds-proxy.md) | ECS Service Connect / VPC Lattice / RDS Proxy の使い所のまとめ |
