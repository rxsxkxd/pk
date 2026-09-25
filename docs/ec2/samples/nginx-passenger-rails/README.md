# サンプル: nginx + Passenger + Rails（EC2 単体 / CloudFormation）

> 目的: [EC2 へのファイル配備 — CloudFormation + S3 + UserData](../../cfn-s3-userdata-provisioning.md) の考え方を、最小構成で動かして確認するためのサンプル
>
> 本番利用は想定しない（HTTP のみ、単体インスタンス、SQLite、アプリはその場で生成）

## 構成

| 項目 | 内容 |
|---|---|
| OS | Ubuntu 24.04 LTS（SSM パブリックパラメータで最新 AMI を解決） |
| Web サーバー | nginx（Ubuntu 標準パッケージ） |
| アプリサーバー | Phusion Passenger（Phusion の APT リポジトリの nginx モジュール `libnginx-mod-http-passenger`） |
| Ruby / Rails | Ruby は Ubuntu 標準の `ruby-full`、Rails は `gem install`（既定 `~> 8.0.0`） |
| DB | SQLite（Rails の既定） |
| アプリ | `rails new --minimal` で生成したデモアプリ。`/` にホスト名・Ruby / Rails のバージョンを表示 |
| 接続 | HTTP（ポート 80）。シェルは SSM Session Manager（SSH・キーペアなし） |

Ubuntu を選んでいるのは、Passenger の nginx モジュールが公式 APT リポジトリでパッケージとして提供されており、ソースからのビルド（`passenger-install-nginx-module`）が不要なため。

作成されるリソース:

| リソース | 内容 |
|---|---|
| `WebSecurityGroup` | ポート 80 を `AllowedCidr` から許可 |
| `InstanceRole` / `InstanceProfile` | `AmazonSSMManagedInstanceCore` のみ |
| `LaunchTemplate` | AMI、IMDSv2 必須、パブリック IP 付与、暗号化 gp3 20 GB、UserData |
| `Instance` | `CreationPolicy` で UserData の完了（`cfn-signal`）を最大 30 分待つ |

## UserData の処理内容

[実行権限の補足](../../userdata-cfn-init-privileges.md)のとおり UserData は root で実行される。アプリの生成・`bundle install` は専用ユーザー `rails` に `runuser` で権限を下げて実行する。

1. `aws-cfn-bootstrap` を venv に導入（Ubuntu には `cfn-signal` が同梱されていないため）し、失敗時に `cfn-signal -e 1` を送る `trap` を設定
2. Ruby、ビルドツール、Rails をインストール
3. Phusion の APT リポジトリを追加し、nginx と Passenger モジュールをインストール
4. ユーザー `rails` で `/var/www/demo` に Rails アプリを生成し、トップページとルートを追加
5. HTTP で動かすため、Rails 8 の production で既定有効の `force_ssl` / `assume_ssl` を無効化
6. `bundle install`（`vendor/bundle`）、`db:prepare`、`assets:precompile`
7. nginx のサイト設定（`passenger_enabled on`）を配置して再起動
8. `http://localhost/up`（Rails のヘルスチェック）と `/` を確認できたら `cfn-signal -e 0`

Passenger はアプリを `config.ru` の所有者（`rails`）の権限で起動する。

## デプロイ

前提: インターネットゲートウェイへのルートを持つパブリックサブネット。

```bash
aws cloudformation deploy \
  --stack-name passenger-rails-sample \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    VpcId=vpc-xxxxxxxx \
    SubnetId=subnet-xxxxxxxx \
    AllowedCidr=203.0.113.10/32

aws cloudformation describe-stacks \
  --stack-name passenger-rails-sample \
  --query 'Stacks[0].Outputs' --output table
```

スタックの作成には 10〜15 分程度かかる（パッケージと gem のインストールが大半）。`Url` の出力をブラウザで開くとトップページが表示される。

| パラメータ | 既定値 | 説明 |
|---|---|---|
| `VpcId` | — | セキュリティグループを作る VPC |
| `SubnetId` | — | パブリックサブネット |
| `AllowedCidr` | `0.0.0.0/0` | HTTP を許可する送信元。自分の IP に絞ることを推奨 |
| `InstanceType` | `t3.small` | gem のビルドがあるため micro はメモリ不足の恐れがある |
| `ImageId` | Ubuntu 24.04 の SSM パラメータ | 固定したい場合は AMI ID を直接指定 |
| `RailsVersion` | `~> 8.0.0` | `gem install rails -v` に渡す |

## 動作確認・調査

```bash
aws ssm start-session --target <InstanceId>
```

Session Manager では `sh` が起動するため、`bash -l` を実行してから作業するとよい（[シェル環境の補足](../../shell-environment-customization.md#session-manager-で接続する場合)）。

| 確認内容 | コマンド |
|---|---|
| UserData の実行ログ | `sudo tail -n 100 /var/log/cloud-init-output.log` |
| Passenger の状態 | `sudo passenger-status` / `sudo passenger-config validate-install` |
| nginx / アプリのログ | `sudo tail -f /var/log/nginx/error.log`（Rails 8 は production のログを標準出力に出し、Passenger 経由でここに出る） |
| アプリの再起動 | `sudo passenger-config restart-app /var/www/demo` |

スタックが失敗してロールバックされ、インスタンスが消えて調べられない場合は、`--disable-rollback` を付けてデプロイし直す。

## 削除

```bash
aws cloudformation delete-stack --stack-name passenger-rails-sample
```

## 実運用に近づけるには

このサンプルは確認用に簡略化している。実際の構成では次を検討する。

| 項目 | サンプル | 実運用での対応 |
|---|---|---|
| アプリの入手 | インスタンス上で `rails new` | CI でビルドした成果物を S3 に置き、UserData で取得（[ファイル配備のドキュメント](../../cfn-s3-userdata-provisioning.md#実装例)）。インスタンスロールに `s3:GetObject` を追加し、AWS CLI を導入する（Ubuntu では `snap install aws-cli --classic`） |
| 更新 | 更新手段なし | インスタンス置換、SSM、CodeDeploy 等（[更新戦略](../../cfn-s3-userdata-provisioning.md#更新戦略)） |
| HTTPS | なし（`force_ssl` を無効化） | ALB + ACM、または Let's Encrypt（[Let's Encrypt のドキュメント](../../letsencrypt-automation.md)）。HTTPS 化したら `force_ssl` / `assume_ssl` を有効に戻す |
| DB | SQLite（インスタンス上） | RDS。接続情報は Secrets Manager / Parameter Store から取得 |
| シークレット | `rails new` で生成した `master.key` がインスタンス上にある | `RAILS_MASTER_KEY` や `SECRET_KEY_BASE` を Secrets Manager から取得し、`passenger_env_var` で渡す |
| Ruby のバージョン | Ubuntu 標準（24.04 では 3.2 系） | アプリが要求するバージョンを rbenv 等で導入し、`passenger_ruby` で指定。起動時間を短くするならカスタム AMI に焼き込む |
| 冗長化 | 単体 | 起動テンプレートを Auto Scaling グループで使い、ALB 配下に置く |
