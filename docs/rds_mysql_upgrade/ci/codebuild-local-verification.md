# CodeBuild 各フローの単体ローカル検証

この文書は、CodePipeline を開始せず、BuildGreen・VerifyGreen・Switchover の各 CodeBuild buildspec を個別にローカル検証する方法をまとめる。実際の AWS 操作を実行する手順を含むため、対象環境と `actions` の承認状態を確認してから使用する。

ローカル検証には二つの粒度がある。

| 粒度 | 実行対象 | 確認できること | 向く用途 |
|---|---|---|---|
| スクリプト直接実行 | `scripts/*.sh` | AWS CLI 呼び出し、設定解析、RDS の判定ロジック | 日常的な確認、特定スクリプトの切り分け |
| CodeBuild Local Agent | `ci/codebuild/*.yml` | buildspec の install/build/artifacts、指定イメージ、環境変数、Docker 利用 | CodeBuild 実行前の互換性確認 |

後者では AWS 提供の `codebuild_build.sh` と Local Agent を Docker で実行する。`-b` でリポジトリ直下以外にある buildspec を明示指定できる。AWS の Local Agent 手順とスクリプトのオプションは [公式ドキュメント](https://docs.aws.amazon.com/codebuild/latest/userguide/use-codebuild-agent.html) および [codebuild_build.sh](https://github.com/aws/aws-codebuild-docker-images/blob/master/local_builds/codebuild_build.sh) を参照する。

## 1. 共通の準備

### 1-1. 必要なローカル環境

- Docker Desktop または Docker Engine
- Git
- 対象 AWS アカウントを読むことができる AWS CLI named profile
- `codebuild_build.sh`
- 軽量実行 image をローカルで build できるネットワーク
- VerifyGreen の場合は、追加で `golang:1.25` と Go module を取得できるネットワーク

CodeBuild Local Agent はホストの AWS 設定を `-c` でコンテナへ渡せる。profile を明示する場合は `-p <profile>` を併用する。ローカル credential の IAM 権限は、AWS 上の CodeBuild 実行ロールとは別物である。原則として読み取り専用 profile を使い、Step 3・5 の変更確認は `pending` 設定で行う。

### 1-2. Docker image の事前準備

`codebuild_build.sh` の初回実行時に image の pull・ビルドを行わせる代わりに、以下を事前に実行できる。コマンドは**列挙のみ**であり、この文書作成時点では実行していない。

#### CodeBuild Local Agent と実行 image の役割

Local Agent と実行 image は別のコンテナである。

```text
ホスト
  └─ CodeBuild Local Agent: public.ecr.aws/codebuild/local-builds:latest
       └─ 実行 image: rds-codebuild-runner:local-<architecture>
            └─ ci/codebuild/*.yml の install / build フェーズを実行
```

| 種類 | イメージ | 担当する役割 |
|---|---|---|
| CodeBuild Local Agent | `public.ecr.aws/codebuild/local-builds:latest`（ARM では `:aarch64`） | `codebuild_build.sh` から受け取ったソース、AWS 設定、環境変数、artifact 出力先、buildspec を実行 image へ受け渡す制御役 |
| 実行 image | `rds-codebuild-runner:local-amd64` または `rds-codebuild-runner:local-arm64` | AWS 上と同じ buildspec の `install`／`build` フェーズを、ローカル検証用の軽量 image で実行する環境 |

`codebuild_build.sh` の `-i rds-codebuild-runner:local-<architecture>` は後者の実行 image を指定する。Local Agent 自体は buildspec を直接実行するための汎用制御コンテナであり、Python・AWS CLI・本リポジトリのスクリプトは実行 image 側で動く。VerifyGreen だけは、実行 image の中からさらに `golang:1.25` を一時的に起動し、Go レポート生成バイナリをビルドする。AWS 上の CodeBuild はこの image を使わず、引き続き `aws/codebuild/standard:7.0` を使う。

Local Agent と実行 image は同じ CPU アーキテクチャでそろえる。ネイティブ実行を基本とし、`x86_64`（Docker の platform 表記では `linux/amd64`）と `arm64` で混在させない。

```bash
# x86_64 / Intel Mac / AMD64 Linux
docker pull --platform linux/amd64 public.ecr.aws/codebuild/local-builds:latest

# ARM64 / Apple Silicon / ARM64 Linux
docker pull --platform linux/arm64 public.ecr.aws/codebuild/local-builds:aarch64

# x86_64 用: Local Agent 専用の軽量実行 image を作成する。
# Python 3.11、PyYAML、AWS CLI v2、Docker CLI/Buildx を含む。
docker build \
  --platform linux/amd64 \
  --tag rds-codebuild-runner:local-amd64 \
  --file ci/Dockerfile.codebuild-runner \
  .

# ARM64 用: Local Agent 専用の軽量実行 image を作成する。
docker build \
  --platform linux/arm64 \
  --tag rds-codebuild-runner:local-arm64 \
  --file ci/Dockerfile.codebuild-runner \
  .

```

実行時は、x86_64 では `-i rds-codebuild-runner:local-amd64`、arm64 では `-i rds-codebuild-runner:local-arm64` を指定する。以降の例では、先に次の変数を設定する。

```bash
# x86_64 の場合
export CODEBUILD_LOCAL_ARCH=amd64
export CODEBUILD_LOCAL_AGENT_IMAGE=public.ecr.aws/codebuild/local-builds:latest

# ARM64 の場合
export CODEBUILD_LOCAL_ARCH=arm64
export CODEBUILD_LOCAL_AGENT_IMAGE=public.ecr.aws/codebuild/local-builds:aarch64
```

異なるアーキテクチャを `--platform` でエミュレーション実行することもできるが、Local Agent・Docker-in-Docker・Go ビルドが遅くなり、ローカル互換性確認としては推奨しない。

#### Echo buildspec 用の事前確認

`ci/codebuild/echo.yml` は Go レポート生成器や Docker Buildx を必要としない。前記で作成した `rds-codebuild-runner:local-${CODEBUILD_LOCAL_ARCH}` と、選択した Local Agent image だけで実行する。したがって、最初のローカル検証は Echo buildspec を使い、実行 image の pull・build、Local Agent、buildspec、artifact 出力までを先に確認する。

AWS の CodeBuild Local Agent は `-i` で指定した build image と `-a` の artifact 出力先を必須とする。AWS 管理 image のローカルビルド方法は [Local Agent 公式手順](https://docs.aws.amazon.com/codebuild/latest/userguide/use-codebuild-agent.html) を参照する。

### 1-3. Local Agent スクリプトの取得

本リポジトリの `ci/codebuild_build.sh` は、AWS 提供の Local Agent helper をベースに、`-b` で指定した buildspec をソースディレクトリからの相対パスとして Agent に渡す対応を加えた版である。リポジトリのファイルをそのまま使用する。

```bash
chmod +x ci/codebuild_build.sh
```

以降の共通コマンドでは `-l "$CODEBUILD_LOCAL_AGENT_IMAGE"` を渡すため、x86_64・arm64 のどちらでも、前節で選択した Local Agent を明示的に使う。

### 1-4. CodeBuild 用の環境変数ファイル

`codebuild_build.sh -e` に渡すローカル専用ファイルを作る。以下は例であり、Git 管理しない。

```dotenv
CONFIG_FILE=config/blue-green/staging.yml
SERVICE_NAME=example-service

# VerifyGreen の通常確認では false。Green DB への接続は行わない。
COLLECT_MYSQL_RUNTIME_VALUES=false
# true の場合だけ必要。secret の値そのものは書かない。
# MYSQL_CREDENTIALS_SECRET_ID=your-secret-id-or-arn
```

リポジトリ直下に `.local/codebuild-local.env` として保存する。`.local/` は Git 管理対象外であり、`-m` でリポジトリをマウントする場合に Docker Desktop の共有パスとしても扱える。

```bash
mkdir -p .local
# エディタで .local/codebuild-local.env を作成し、上記の VAR=VAL を保存する。
```

`codebuild_build.sh` の環境変数ファイルは `VAR=VAL` 形式であり、引用符も値の一部として扱われるため、値を引用符で囲まない。

### 1-5. 共通コマンド形式

`-b` は CodeBuild Local Agent の公式ヘルパーでサポートされる buildspec override オプションであり、`ci/codebuild/<flow>.yml` を指定する用途に適している。`-b` の値は `CODEBUILD_SRC_DIR` からの相対パスで指定する。たとえば `-s .` の場合は `ci/codebuild/echo.yml` とし、`/Users/.../ci/codebuild/echo.yml` のようなホスト絶対パスは指定しない。Local Agent が source を build コンテナへ渡した後、その内部の source directory から buildspec を読むためである。

```bash
./ci/codebuild_build.sh \
  -i rds-codebuild-runner:local-${CODEBUILD_LOCAL_ARCH} \
  -l "$CODEBUILD_LOCAL_AGENT_IMAGE" \
  -a artifacts/codebuild-local/<flow> \
  -s . \
  -b ci/codebuild/<flow>.yml \
  -e .local/codebuild-local.env \
  -c -p your-aws-profile -m
```

| オプション | 用途 |
|---|---|
| `-i` | Local Agent 用の軽量実行 image を指定。AWS 上は CloudFormation 定義どおり `aws/codebuild/standard:7.0` を使う |
| `-a` | buildspec の `artifacts` をローカルへ出力するディレクトリ |
| `-s .` | 現在のリポジトリを primary source として指定 |
| `-b` | 実行する buildspec を指定。上記の local helper 修正後に使用する |
| `-e` | `CONFIG_FILE`、`SERVICE_NAME` 等のローカル環境変数ファイル |
| `-c -p` | ホストの `~/.aws` と指定 profile を Local Agent へ渡す |
| `-m` | ソースをコピーせず、ホストの作業ディレクトリを直接マウント |

`-m` を使う場合、build の生成物 `.tools/` や `artifacts/` がホストの作業ディレクトリへ残ることがある。検証後に内容を確認してから削除する。

### 1-6. Echo buildspec による成功確認

共通準備の完了確認には、`ci/codebuild/echo.yml` を実行する。この buildspec は AWS API を呼ばず、`install` と `build` でメッセージ・Python・AWS CLI のバージョン・環境変数を出力する。BuildGreen・VerifyGreen・Switchover より先に、Local Agent、実行 image、buildspec の指定、artifact 出力の疎通を確認できる。

### x86_64（Intel Mac / AMD64 Linux）

```bash
./ci/codebuild_build.sh \
  -i rds-codebuild-runner:local-amd64 \
  -l public.ecr.aws/codebuild/local-builds:latest \
  -a artifacts/codebuild-local/echo \
  -s . \
  -b ci/codebuild/echo.yml \
  -e .local/codebuild-local.env \
  -m
```

### arm64（Apple Silicon / ARM64 Linux）

```bash
./ci/codebuild_build.sh \
  -i rds-codebuild-runner:local-arm64 \
  -l public.ecr.aws/codebuild/local-builds:aarch64 \
  -a artifacts/codebuild-local/echo \
  -s . \
  -b ci/codebuild/echo.yml \
  -e .local/codebuild-local.env \
  -m
```

この buildspec は AWS API を実行しないため、`-c -p your-aws-profile` は不要である。arm64 は `INSTALL`、`BUILD`、`UPLOAD_ARTIFACTS` の成功を確認済みである。`-m` を指定した場合、buildspec が作る `artifacts/echo-result.txt` は作業ツリー直下に残る。`-a artifacts/codebuild-local/echo` 側には CodeBuild Local Agent が収集した `artifacts.zip` が出力される。

## 2. BuildGreen 単体検証

対象 buildspec は `ci/codebuild/build-green.yml`、実処理は `scripts/build_green.sh` である。

### 変更を行わない検証

`config/blue-green/staging.yml` の対象サービスで `actions.build: pending` を確認してから、次を実行する。

```bash
./ci/codebuild_build.sh \
  -i rds-codebuild-runner:local-${CODEBUILD_LOCAL_ARCH} \
  -l "$CODEBUILD_LOCAL_AGENT_IMAGE" \
  -a artifacts/codebuild-local/build-green \
  -s . \
  -b ci/codebuild/build-green.yml \
  -e .local/codebuild-local.env \
  -c -p your-readonly-profile -m
```

この状態では `build_green.sh` が `pending` を検出して終了するため、RDS API の変更操作は行わない。確認対象は Python と PyYAML の存在、環境変数の受け渡し、buildspec の構文、成果物出力先である。

### 実 AWS 操作を含む検証

`actions.build: approved` の場合は、同じコマンドが保護スナップショット作成と Blue/Green deployment 作成を実行する。実行する場合は、検証専用 DB・snapshot 名・パラメータグループを使い、ローカル profile に Step 3 の変更権限があることを確認する。本番 DB に対するローカル実行は通常行わない。

## 3. VerifyGreen 単体検証

対象 buildspec は `ci/codebuild/verify-green.yml`、実処理は `scripts/verify_green.sh` である。VerifyGreen は Go レポート生成器を Docker のマルチステージビルドで生成するため、共通コマンドに `-d` を追加する。

```bash
./ci/codebuild_build.sh \
  -i rds-codebuild-runner:local-${CODEBUILD_LOCAL_ARCH} \
  -l "$CODEBUILD_LOCAL_AGENT_IMAGE" \
  -a artifacts/codebuild-local/verify-green \
  -s . \
  -b ci/codebuild/verify-green.yml \
  -e .local/codebuild-local.env \
  -c -p your-readonly-profile -m -d
```

この通常モード（`COLLECT_MYSQL_RUNTIME_VALUES=false`）は、Green DB へ MySQL 接続を行わない。実行すると AWS 読み取り API、CloudWatch `ReplicaLag`、Docker Buildx、Go バイナリ生成、レポート出力を確認する。対象の Blue/Green deployment が実在しない場合は、期待どおり検証が失敗する。

### MySQL 実効値収集を含める場合

環境変数ファイルを次のように変更する。

```dotenv
COLLECT_MYSQL_RUNTIME_VALUES=true
MYSQL_CREDENTIALS_SECRET_ID=your-secret-id-or-arn
```

この場合、Local Agent 内で Secrets Manager から secret を取得し、必要なら apt で MySQL client を導入して Green DB へ接続する。ホスト Docker から Green DB へネットワーク到達できること、local profile に `secretsmanager:GetSecretValue` があること、secret の JSON が `username`／`password` を持つことを事前に確認する。通常のローカル検証では有効化しない。

## 4. Switchover 単体検証

対象 buildspec は `ci/codebuild/switchover.yml`、実処理は `scripts/switchover.sh` である。buildspec は `--approve` を常に渡すが、`actions.switchover` が `pending` であればスクリプトは変更せず終了する。

```bash
./ci/codebuild_build.sh \
  -i rds-codebuild-runner:local-${CODEBUILD_LOCAL_ARCH} \
  -l "$CODEBUILD_LOCAL_AGENT_IMAGE" \
  -a artifacts/codebuild-local/switchover \
  -s . \
  -b ci/codebuild/switchover.yml \
  -e .local/codebuild-local.env \
  -c -p your-readonly-profile -m
```

`actions.switchover: approved` に変えると、`AVAILABLE` 状態の Blue/Green deployment を実際に切り替える。ローカル検証目的では `pending` のままにし、本番切替を Local Agent から実行しない。

## 5. スクリプト直接実行との使い分け

CodeBuild Local Agent の不具合とスクリプト本体の不具合を分けるため、同じ設定でシェルスクリプトを直接実行できる。例えば VerifyGreen の通常モードは次のとおりである。

```bash
scripts/verify_green.sh \
  --config config/blue-green/staging.yml \
  --service example-service \
  --profile your-readonly-profile \
  --output-dir artifacts/verify-green-direct
```

ただしこの直接実行は CodeBuild の Python runtime、PyYAML install、Docker Buildx、buildspec artifacts を検証しない。CodeBuild 導入前の最終確認には、各節の Local Agent コマンドを使う。

直接実行では事前に `python3 -m pip install 'PyYAML==6.0.2'` が必要である。また `GREEN_REPORT_GENERATOR` を指定しない VerifyGreen は、互換用に残している Ruby 版のレポート生成器を使う。CodeBuild と同じ Go バイナリ経路を確認する目的には、必ず Local Agent の VerifyGreen 手順を使う。

## 6. 実行しない確認項目

AWS へ接続せずに確認する場合は、以下だけを行う。

```bash
# buildspec YAML の構文確認
ruby -e 'require "yaml"; Dir["ci/codebuild/*.yml"].each { |f| YAML.load_file(f) }; puts "OK"'

# シェル構文確認
bash -n scripts/build_green.sh scripts/verify_green.sh scripts/switchover.sh
```

これらは CodeBuild managed image・Python package・Docker・AWS API・IAM・ネットワークを検証しない。実行環境の互換性確認には Local Agent を用いる。
