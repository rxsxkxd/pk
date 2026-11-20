# CodeBuild のビルド環境の Ruby の入手元

AMI 公開ツールを動かす CodeBuild のビルド環境で、Ruby がどこから入っているかを整理する。CodeBuild で使う Ruby を「イメージに入っている 3.4 系の最新」に自動で合わせる案（案 A: `rbenv versions` から選ぶ）の前提を確かめるためのもの。

## 用語

| 用語 | 意味 |
|---|---|
| CodeBuild のビルド環境 | CodeBuild プロジェクト `ami-publish` がビルドのたびに起動するコンテナ。イメージは `aws/codebuild/standard:8.0`（`internal/definitions/ami_publish_buildspec.go` の `codeBuildImage`） |
| イメージ定義 | CodeBuild 標準イメージの元になる Dockerfile と `runtimes.yml`（GitHub の `aws/aws-codebuild-docker-images`） |
| イメージの Ruby | イメージを作るときにインストール済みの Ruby。ビルドのたびのインストールは要らない |
| OS パッケージ | Ubuntu の apt（`apt-get install`）で入れるパッケージ |

## 入手元の 3 つのパターン

| パターン | 中身 | Ruby の置き場所（例） | 3.4 系の最新への追従 |
|---|---|---|---|
| 1. OS パッケージの Ruby | apt の `ruby` などをそのまま使う。rbenv は使わない | `/usr/bin/ruby` | Ubuntu のパッケージの更新次第。Ubuntu 24.04 の Ruby は 3.2 系の想定で（未確認）、3.4 系にはならない |
| 2. OS パッケージの ruby-build で入れた Ruby | apt の `rbenv` / `ruby-build` を入れ、`rbenv install` でソースからビルドする | `~/.rbenv/versions/<バージョン>` | ruby-build のパッケージが古いと、新しいパッチの定義がなく入れられない（Ubuntu 24.04 のパッケージの版は未確認） |
| 3. 自前でインストールした ruby-build で入れた Ruby | rbenv と ruby-build を GitHub から git clone し、`rbenv install` でソースからビルドする | `$(rbenv root)/versions/<バージョン>` | ruby-build を `git pull` すれば最新の定義を使える（ビルドの時間はかかる） |

ほかに、mise・asdf などの別のバージョン管理ツールや、公式の Ruby の Docker イメージ（Ruby は `/usr/local` にビルド済み）もあるが、今の構成とは関係しないので扱わない。

## 今のイメージはパターン 3（イメージ定義から）

`ubuntu/standard/8.0` のイメージ定義（master）を読んだ結果（2026-11-20）。

- **rbenv**: `git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv`。版の固定はない
- **ruby-build**: `git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build` の後に `sh .../install.sh`。版の固定はなく、`.git` は消していない（`git pull` できる見込み）。`install.sh` は既定で `/usr/local/bin` にも ruby-build をコピーするので、ruby-build が 2 か所にある可能性がある（未確認）
- **RBENV_ROOT**: 設定していない。`PATH` には `/root/.rbenv/shims` と `/usr/local/rbenv/shims` の両方が入っている。Ruby の置き場所は既定の `/root/.rbenv/versions` の見込み（未確認）
- **イメージの Ruby**: `rbenv install` で 4.0.9・3.4.12・3.3.13 をビルド済み。`rbenv global` は 4.0.9
- **OS パッケージ**: `ruby`・`ruby-dev`・`rbenv`・`ruby-build` はどれも入れていない。Ruby のビルドに使うライブラリ（`libssl-dev`・`libyaml-dev`・`zlib1g-dev`・`libffi-dev`・`libreadline-dev` など）と `build-essential` は入っている
- **`runtimes.yml` の `ruby`**: `runtime-versions` に `3.4` などを指定すると、`rbenv global` でイメージの Ruby を選ぶ。イメージにないバージョンを指定すると `rbenv install` でビルドする

注意: イメージ定義の master と、CodeBuild が今実際に使っているイメージが同じとは限らない（AWS がイメージを更新して公開する時期は別）。以前（2026-10-21）に読んだときは 3.4 系が 3.4.10 だった。このため buildspec はバージョンを書かず、`rbenv versions` からイメージにある 3.4 系の最新を選ぶ形にした（案 A。2026-11-20）。

## 実環境で確かめる方法

### どこで流すか

パイプラインを動かさずに、CodeBuild プロジェクトだけをビルドスペックを差し替えて起動する。`generated/` の buildspec は変えない。

```bash
aws codebuild start-build \
  --project-name <CodeBuild プロジェクト名> \
  --source-type-override NO_SOURCE \
  --buildspec-override file://ruby-source-check-buildspec.yml
```

- CodeBuild プロジェクト名は、仕組みの生成ツールを実行したときに表示される名前の一覧で確かめる
- ソースは要らないので `NO_SOURCE` にする。CodePipeline から起動する前提のプロジェクトでも、これで単独で起動できる見込み（実機では試していない）
- 結果は CodeBuild のログ（CloudWatch Logs）で見る
- 手元で `docker pull` してイメージを調べる方法もあるが、イメージが大きい（数 GB）うえ、CodeBuild が今使っている版と同じとは限らないので勧めない

### 確かめるコマンド（`ruby-source-check-buildspec.yml`）

```yaml
version: 0.2
phases:
  build:
    commands:
      # Ruby の実体と版
      - command -v ruby; ruby --version
      # rbenv の場所と、Ruby の置き場所（rbenv root）
      - command -v rbenv; rbenv --version; rbenv root
      # イメージの Ruby の一覧（案 A はここから選ぶ）と、既定の Ruby
      - rbenv versions; rbenv global
      # ruby-build の場所と版（2 か所にあるかも見る）
      - command -v -a ruby-build || true
      - ruby-build --version || true
      - ls -d /usr/local/rbenv/plugins/* "$(rbenv root)"/plugins/* 2>/dev/null || true
      - git -C /usr/local/rbenv/plugins/ruby-build log -1 --format='%H %cd' || true
      # ruby-build が知っている 3.4 系の最新（新しいパッチを入れられるか）
      - ruby-build --definitions | grep '^3\.4\.' | tail -n 3 || true
      # OS パッケージ由来かどうか
      - dpkg -S "$(command -v ruby)" "$(command -v ruby-build)" 2>&1 || true
      - dpkg -l | grep -Ei 'ruby|rbenv' || true
```

### 結果の読み方

| 確かめること | パターン 1 | パターン 2 | パターン 3 |
|---|---|---|---|
| `command -v ruby` | `/usr/bin/ruby` | `.../shims/ruby` | `.../shims/ruby` |
| `dpkg -S`（ruby） | パッケージ名が出る | 出ない（shims） | 出ない（shims） |
| `command -v -a ruby-build` | なし | `/usr/bin/ruby-build` | `/usr/local/bin/ruby-build` や `/usr/local/rbenv/plugins/ruby-build/bin/ruby-build` |
| `dpkg -S`（ruby-build） | — | `ruby-build` のパッケージ名が出る | 出ない |
| `git -C .../plugins/ruby-build log` | — | 失敗する | コミットと日時が出る |

ほかに見ておくこと:

- `rbenv versions` に 3.4 系がいくつあり、最新はどれか（案 A で選ばれる版）
- `rbenv root` が `/root/.rbenv` か `/usr/local/rbenv` か（Ruby の置き場所）
- `ruby-build --definitions` の 3.4 系の最新が、イメージの Ruby より新しいか（パターン 3 のまま、ビルドすれば新しいパッチを使えるか）

## 参考

- CodeBuild 標準イメージ 8.0 のイメージ定義: https://github.com/aws/aws-codebuild-docker-images/blob/master/ubuntu/standard/8.0/Dockerfile ・ https://github.com/aws/aws-codebuild-docker-images/blob/master/ubuntu/standard/8.0/runtimes.yml （2026-11-20 に master を読んだ。どのコミットかは控えていない）
- `start-build` の上書きのオプション（`--source-type-override`・`--buildspec-override`）は、AWS CLI のリファレンスではまだ確かめていない（2026-11-20 時点）
