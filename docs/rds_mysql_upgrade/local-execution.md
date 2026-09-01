# コンテナでの AWS CLI・MySQL クライアント実行

リポジトリルートの `compose.yaml`、`aws-config/`(ディレクトリ)、`global-bundle.pem`・`my.cnf`(ファイル)は、AWS CLI、`mysql`、`mysqlsh` をローカルインストールせずに実行するためのものです。DB インスタンスやパラメータグループを作成・変更する権限を付与するものではありません。実行できる AWS 操作は、マウントした認証情報に付与された IAM 権限に従います。

使用するコンテナは 4 つである。`public.ecr.aws/aws-cli/aws-cli:2.32.25`、MySQL CLI と MySQL Shell を同梱する公式イメージ `mysql:8.4.8`、`ruby:3.4`、`golang:1.25` を使用する。`latest` タグは使用しない。AWS CLI と MySQL はパッチバージョンまで、Ruby と Go はメジャー・マイナーまでを固定する。

> 現時点では定義ファイルと手順のみを用意しており、イメージの取得・実行検証は未実施である。MySQL 用の Dockerfile は不要であり、初回実行時に `mysql:8.4.8` が取得される。

CI（CodeBuild Local Agent、Step 4 の Go レポート生成器ビルド）専用のコンテナ定義は [ci/](ci/) 配下にある。本書が扱うのは、Step 1・2 や DB 接続確認など、ローカルでの通常の作業に使うコンテナだけである。

## 1. ホスト側の準備

`global-bundle.pem`・`my.cnf` はディレクトリではなく単一ファイルを直接 bind mount する。Docker はマウント元のファイルが存在しないと空ディレクトリを自動生成してしまうため、**実体のないまま `docker compose run` すると意図しない空ディレクトリができる**。

`my.cnf` は空プレースホルダとしてリポジトリに追跡済みであり、clone した時点で既に存在する。**実接続情報を書き込んだまま commit しないこと。** DB ユーザーやパスワードを保存したい場合は、直接編集せず `.env` の `MYSQL_CLIENT_CONFIG_FILE` でリポジトリ外の絶対パスを指す。

`global-bundle.pem` は Git 管理外なので、実接続時に取得する。

```bash
curl -o global-bundle.pem \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
cp .env.example .env
```

いずれもリポジトリ外の絶対パスに置きたい場合は、`.env` の `RDS_CA_FILE`／`MYSQL_CLIENT_CONFIG_FILE` でファイルパスを直接指定する（ディレクトリではなくファイルそのものを指す）。

`.env` は実接続時だけ作成し、値を絶対パスに置き換える。`aws-config/` は今回もディレクトリ mount のまま維持しており、`global-bundle.pem`／`my.cnf` のファイル化とは無関係に、AWS 認証の扱い（SSO のキャッシュディレクトリを含む）は変わらない。未作成でも `docker compose create` は可能で、その場合は Git 管理下の空ディレクトリを読み取り専用でマウントする（空ディレクトリでは AWS 認証はできない）。AWS SSO を利用する場合は、ホスト上で先に `aws sso login --profile <profile>` を完了する。

任意で、DB 接続情報を `my.cnf` に保存できる。ただしリポジトリ直下の `my.cnf` は追跡済みファイルであるため、パスワードなど実接続情報を書き込む場合は `.env` の `MYSQL_CLIENT_CONFIG_FILE` でリポジトリ外の絶対パスを指し、そちらのファイルに `chmod 600` を設定する。

```ini
[client]
host=<rds-endpoint>
user=<db-user>
# password は可能なら記載せず、実行時に -p で入力する
ssl-mode=VERIFY_CA
ssl-ca=/certs/rds/global-bundle.pem
```

`my.cnf` はコンテナの `/client-config/my.cnf` として読み取り専用でマウントされる。RDS CA bundle は `/certs/rds/global-bundle.pem` として読み取り専用でマウントされる。

## 2. Docker Compose で実行する

リポジトリのルートから実行する。

```bash
# AWS 認証・プロファイルを確認
docker compose --env-file .env run --rm awscli sts get-caller-identity

# Phase 0 の読み取り収集
docker compose --env-file .env run --rm awscli \
  rds describe-db-instances --db-instance-identifier <blue-instance-id>

# mysql。my.cnf を使い、パスワードは必要時に対話入力する
docker compose --env-file .env run --rm mysql \
  mysql --defaults-extra-file=/client-config/my.cnf -p \
  -e "SELECT VERSION();"

# mysqlsh。同じ mysql コンテナで接続情報を明示する例
docker compose --env-file .env run --rm mysql \
  mysqlsh \
  --sql --host=<rds-endpoint> --user=<db-user> --password \
  --ssl-mode=VERIFY_CA --ssl-ca=/certs/rds/global-bundle.pem \
  -e "SELECT VERSION();"

# Ruby スクリプトの実行
docker compose --env-file .env run --rm ruby \
  scripts/generate_mysql84_parameter_group.rb --help

# Go プログラムの実行
docker compose --env-file .env run --rm go version
```

`mysql:8.4.8` は公式のマルチアーキテクチャイメージであり、Docker がホストに対応するイメージを選択する。

## 3. `docker run` で直接実行する

`docker compose` を使わない場合も、同じボリュームを明示して実行できる。以下では、`AWS_CONFIG_DIR`（ディレクトリ）、`RDS_CA_FILE`、`MYSQL_CLIENT_CONFIG_FILE`（いずれもファイルそのもの）をホスト上の絶対パスとして設定済みとする。

```bash
# AWS CLI（認証情報を read-only マウント）
docker run --rm -it \
  -v "$AWS_CONFIG_DIR:/root/.aws:ro" \
  -v "$(pwd):/workspace" -w /workspace \
  -e AWS_SDK_LOAD_CONFIG=1 -e AWS_PROFILE="${AWS_PROFILE:-default}" \
  public.ecr.aws/aws-cli/aws-cli:2.32.25 \
  rds describe-db-instances --db-instance-identifier <blue-instance-id>

# mysql（RDS CA と接続設定を read-only マウント）
docker run --rm -it \
  -v "$RDS_CA_FILE:/certs/rds/global-bundle.pem:ro" \
  -v "$MYSQL_CLIENT_CONFIG_FILE:/client-config/my.cnf:ro" \
  mysql:8.4.8 \
  mysql --defaults-extra-file=/client-config/my.cnf -p -e "SELECT VERSION();"

# mysqlsh（上記と同じ公式イメージ）
docker run --rm -it \
  -v "$RDS_CA_FILE:/certs/rds/global-bundle.pem:ro" \
  -v "$MYSQL_CLIENT_CONFIG_FILE:/client-config/my.cnf:ro" \
  mysql:8.4.8 \
  mysqlsh --sql --host=<rds-endpoint> --user=<db-user> --password \
  --ssl-mode=VERIFY_CA --ssl-ca=/certs/rds/global-bundle.pem \
  -e "SELECT VERSION();"

# Ruby。AWS credential・RDS 証明書はマウントしない
docker run --rm -it -v "$(pwd):/workspace" -w /workspace \
  ruby:3.4 scripts/generate_mysql84_parameter_group.rb --help

# Go。AWS credential・RDS 証明書はマウントしない
docker run --rm -it -v "$(pwd):/workspace" -w /workspace \
  golang:1.25 version
```

## セキュリティ上の注意

- `.env`、AWS credential、CA bundle は Git 管理しない。リポジトリ直下の `my.cnf` は空プレースホルダとして例外的に追跡しているため、実接続情報を書き込んだまま commit しない。
- AWS 認証情報と接続設定はすべて `:ro` でマウントする。コンテナから認証情報を変更しない。
- DB パスワードを Compose ファイル、コマンド履歴、環境変数に書かない。`-p`／`--password` による対話入力、またはアクセス権を制限した Git 管理外の `my.cnf`（`.env` の `MYSQL_CLIENT_CONFIG_FILE` で指す）を使う。
- 本番接続には `VERIFY_CA` 以上を使い、RDS の CA ローテーション時はホスト側の CA bundle を更新する。
- AWS CLI と MySQL は公式コンテナを使用する。組織のイメージ許可・脆弱性スキャン方針に従って、固定タグを検証または社内レジストリへ取り込む。

## 参考

- [AWS CLI v2 の公式 Docker イメージ](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-docker.html)
- [RDS SSL/TLS の CA bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
- [MySQL Shell 8.4](https://dev.mysql.com/doc/mysql-shell/8.4/en/)
