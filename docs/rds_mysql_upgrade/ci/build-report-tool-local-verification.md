# BuildReportTool のローカル検証手順

`ci/codebuild/build-report-tool.yml`（Step 4 の Go レポート生成器のビルド）を、**AWS の CodeBuild に近い構成でこのマシン上だけで実行する**手順である。

対象はこの buildspec 1 本だけである。他のフローの手順は [CodeBuild 各フローの単体ローカル検証](codebuild-local-verification.md)、失敗したときの切り分けは [BuildReportTool の失敗切り分け](build-report-tool-troubleshooting.md) にある。

## 1. なぜこの構成か

AWS 上の `BuildReportToolProject` は `aws/codebuild/standard:7.0` を使うが、**このイメージは 10GB を超えるためローカルには置かない。**代わりに、確認したい相違点だけを満たす小さな既存イメージで代替する。

| 確認したい点 | `standard:7.0` | 代替（`golang:1.25`） |
|---|---|---|
| OS | Ubuntu（Debian 系） | Debian GNU/Linux |
| `find` / `grep` / `dirname` | GNU coreutils / GNU grep | GNU coreutils / **GNU grep 3.11** |
| 実行ユーザー | root | root |
| Go | `runtime-versions: golang: 1.25` で用意 | **Go 1.25 が最初から入っている** |
| `GOPATH` | `/go` | `/go` |
| `/bin/sh` | dash | dash |

**`runtime-versions` を解釈するのは AWS 側のマネージドイメージだけである。**Local Agent もこれを解決しない。`golang:1.25` は最初から Go 1.25 なので結果としては同じ状態になるが、「`standard:7.0` が `golang: 1.25` を選べるか」はローカルでは確認できない（[I1](build-report-tool-troubleshooting.md#i1-unknown-runtime-version-named-125-of-golang)）。

**新しく pull・build するイメージは無い。**必要なものはこのリポジトリの既存手順で既に揃っている。

## 2. 前提

| 資材 | 確認方法 |
|---|---|
| Docker が動いている | `docker info --format '{{.ServerVersion}}'` |
| `golang:1.25` | `docker images golang:1.25` |
| CodeBuild Local Agent | `docker images public.ecr.aws/codebuild/local-builds` |
| Local Agent 起動スクリプト | `ls ci/codebuild_build.sh` |

Local Agent とスクリプトの取得方法は [codebuild-local-verification.md](codebuild-local-verification.md) の「1-2」「1-3」にある。アーキテクチャに応じて Agent のタグが変わる。

```bash
uname -m   # arm64 なら :aarch64、x86_64 なら :latest
```

## 3. 実行

`ci/codebuild_build.sh` は **`-i`（実行 image）と `-a`（artifact 出力先）が必須**である。省略時の既定値は無く、CloudFormation の `Image` を読むこともしない。

### arm64（Apple Silicon）

```bash
./ci/codebuild_build.sh \
  -i golang:1.25 \
  -l public.ecr.aws/codebuild/local-builds:aarch64 \
  -a artifacts/codebuild-local/build-report-tool \
  -s . \
  -b ci/codebuild/build-report-tool.yml
```

### x86_64

```bash
./ci/codebuild_build.sh \
  -i golang:1.25 \
  -l public.ecr.aws/codebuild/local-builds:latest \
  -a artifacts/codebuild-local/build-report-tool \
  -s . \
  -b ci/codebuild/build-report-tool.yml
```

### 他フローの手順との違い

| オプション | 値 | 理由 |
|---|---|---|
| `-i` | `golang:1.25` | このビルドだけ Go が要る。既存の `rds-codebuild-runner:local-<arch>` は Ruby・jq・AWS CLI 入りで **Go を含まない** |
| `-e` | **付けない** | この buildspec は `CONFIG_FILE` も `SERVICE_NAME` も読まない |
| `-c -p <profile>` | **付けない** | AWS API を一切呼ばない |
| `-m` | **付けない** | 下記 |
| `-d` | **付けない** | Docker を使わないため `PrivilegedMode` は不要 |

**`-m` を付けない理由**：`-m` はホストの作業ディレクトリを直接マウントするため、ビルド成果物の **Linux バイナリがホスト側に残る**（`.tools/` は `.gitignore` 済みだが macOS では実行できないものが置かれる）。付けなければソースはコンテナ内へコピーされ、ホストは汚れない。

さらに、今回の検証の主目的は **`-o` の絶対パス指定と `artifacts.files` の宣言が噛み合っているか**の確認である。`-m` 無しの方が実機（CodePipeline が S3 経由で artifact を受け渡す形）に近い。

### TTY が無い環境から実行する場合

`ci/codebuild_build.sh` は内部で `docker run -it` を使うため、**端末が無いと起動できない。**

```
cannot attach stdin to a TTY-enabled container because stdin is not a terminal
```

スクリプトは実行前に組み立てた `docker run` コマンドを表示する。CI やエディタの実行窓など端末が無い場所から回す場合は、その表示から `-it` を外して直接実行する。内容は同じである。

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e "IMAGE_NAME=golang:1.25" \
  -e "ARTIFACTS=$PWD/artifacts/codebuild-local/build-report-tool" \
  -e "SOURCE=$PWD/." \
  -e "BUILDSPEC=ci/codebuild/build-report-tool.yml" \
  -e "LOCAL_AGENT_IMAGE_NAME=public.ecr.aws/codebuild/local-builds:aarch64" \
  -e "INITIATOR=$USER" \
  public.ecr.aws/codebuild/local-builds:aarch64
```

## 4. 成功の判定

`install` → `pre_build` → `build` → `UPLOAD_ARTIFACTS` がすべて成功し、次の出力が揃っていること。

```
go version go1.25.x linux/<arch>          ← install
MODULE_DIR=/codebuild/output/src.../      ← pre_build（構成検査を通過）
rds-mysql-upgrade                         ← go list -m
rds-mysql-upgrade/scripts/generate_green_verification_report (main)   ← go list
rds-mysql-upgrade/scripts/collect_green_runtime_values (main)
-rwxr-xr-x ... generate_green_verification_report   ← build
Usage of .../generate_green_verification_report:    ← 動くバイナリである
```

各行の意味は [失敗切り分けの「正常時のログ」](build-report-tool-troubleshooting.md#5-r-ビルドは成功したのに後段で失敗する) にある。

### 成果物

Local Agent が収集した zip が `-a` に出る。

```bash
ls -l artifacts/codebuild-local/build-report-tool/
unzip -l artifacts/codebuild-local/build-report-tool/artifacts.zip
```

**`.tools/green-report/generate_green_verification_report` が含まれていること**を確認する。これが `artifacts.files` の宣言どおりに収集できたことの証明で、AWS 上では `VerifyGreen` が `CODEBUILD_SRC_DIR_ReportToolOutput` からこれを受け取る。

```bash
# Linux バイナリであることの確認（macOS では実行できない）
unzip -p artifacts/codebuild-local/build-report-tool/artifacts.zip \
  .tools/green-report/generate_green_verification_report | file -
```

## 5. この方法で検証できること・できないこと

| | 項目 |
|---|---|
| **できる** | 構成検査（`MODULE_DIR` の解決）が Linux の GNU find / grep で動くこと |
| | `go build` が Linux で通り、静的リンクのバイナリができること |
| | `-o` の絶対パス指定が `artifacts.files` の宣言と噛み合うこと |
| | フェーズ遷移と、失敗時に後続フェーズを飛ばす挙動 |
| | `env.variables`（`GOTOOLCHAIN: auto`）が適用されること |
| **できない** | `runtime-versions: golang: 1.25` が `standard:7.0` で解決できるか |
| | VPC・ネットワーク到達性（`proxy.golang.org` へ出られるか） |
| | IAM（CodePipeline の `codebuild:StartBuild` 権限など） |

**できないものは実機のログでしか判別できない。**該当するパターンは [失敗切り分け](build-report-tool-troubleshooting.md) の S 節と I 節にまとめてある。

> **`GOTOOLCHAIN` の落とし穴**：`golang` 公式イメージは意図しないツールチェーン取得を防ぐため `GOTOOLCHAIN=local` を既定にしている。buildspec は `env.variables` で `auto` を宣言しているので、**Local Agent 経由なら `auto` が適用される。**buildspec からコマンドだけを抜き出して直接実行する場合は、`env.variables` も自分で適用しないと実機と挙動が変わる（Go が要求より古いときに、落ちるか自動取得するかが変わる）。

## 6. 後片付け

```bash
rm -rf artifacts/codebuild-local/build-report-tool
```

`-m` を付けずに実行した場合、ホストの作業ディレクトリには何も残らない（`.tools/` は作られない）。`artifacts/` は `.gitignore` 済みである。

## 7. 実行記録

2026-09-16、arm64（Apple Silicon）で上記手順を実行した結果。

| フェーズ | 結果 |
|---|---|
| `DOWNLOAD_SOURCE` | SUCCEEDED |
| `INSTALL` | SUCCEEDED（`go version go1.25.14 linux/arm64`） |
| `PRE_BUILD` | SUCCEEDED（`MODULE_DIR=/codebuild/output/srcDownload/src`、`rds-mysql-upgrade`、`rds-mysql-upgrade/scripts (main)`） |
| `BUILD` | SUCCEEDED |
| `UPLOAD_ARTIFACTS` | SUCCEEDED |

収集された `artifacts.zip` の中身は宣言どおり 1 ファイルで、静的リンクの Linux バイナリだった。

```
2556088  .tools/green-report/generate_green_verification_report
ELF 64-bit LSB executable, ARM aarch64, statically linked
```

**この検証で buildspec の実バグを 1 件見つけた。**`CODEBUILD_SRC_DIR` は実体ディレクトリではなく**シンボリックリンク**である。

```
/codebuild/output/src621094900/src -> /codebuild/output/srcDownload/src
```

`find` は起点がシンボリックリンクのとき既定で辿らないため、`find "$CODEBUILD_SRC_DIR" -name go.mod` が 1 件も返さず、構成検査が「go.mod が無い」で落ちていた。**この構造は実際の AWS CodeBuild でも同じなので、本番でも同様に失敗していた。**`pwd -P` で実体へ解決してから探索するよう修正した。

ホスト上で実体ディレクトリを渡して試すだけでは再現しない種類の不具合で、**Local Agent を通したからこそ見つかった。**
