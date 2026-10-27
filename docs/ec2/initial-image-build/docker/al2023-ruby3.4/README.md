# Docker の定義: Amazon Linux 2023 と Ruby 3.4（最新のパッチバージョン）

> 位置付け: 起点の方式の候補のうち「Docker」で、下回り（OS とミドルウェア）の構成を定義し、手元で再現して確かめるためのもの。**EC2 はコンテナイメージから直接起動できない**ため、この定義はそのまま AMI にはならない（[起点の README](../../README.md#方式の候補未決定)）。Ruby の入れ方は [土台の構成](../../base-image-composition.md) の B（ruby-build でソースからビルド）に合わせている。
>
> 確認日: 2026-10-28（手元の arm64 の Mac の Docker Desktop でビルドと動作を確認した）

## AL2023 のパッケージの Ruby を使わない理由

AL2023 のリポジトリの Ruby は、最新のパッチバージョンに追いつかない（2026-10-28 に AL2023 のコンテナイメージ `2023.12.20261026` で確認）。

| 入れ方 | 入る Ruby |
|---|---|
| `dnf install ruby` | **3.2.8**（`ruby` は `ruby3.2` を指す。3.1 ではない） |
| `dnf install ruby3.4` | 3.4.8 |
| この定義（ruby-build） | **3.4.12**（その時点の 3.4 系の最新） |

比べるための、AL2023 のパッケージ（`ruby3.4`）で入れる定義は [Docker の定義（AL2023 のパッケージ）](../al2023-ruby3.4-dnf/README.md)。

## 定義の中身

`Dockerfile` は 2 つの段に分けている。

| 段 | すること |
|---|---|
| ビルドの段（`build`） | コンパイラーと開発用のライブラリ、Rust を入れ、ruby-build で Ruby を `/opt/ruby` にビルドする |
| 実行の段 | 実行時のライブラリだけを入れ、ビルドの段から `/opt/ruby` を写す。コンパイラーや Rust は残らない |

| 項目 | 内容 |
|---|---|
| 土台のイメージ | `public.ecr.aws/amazonlinux/amazonlinux:2023`（ビルドの引数 `AL2023_IMAGE` で変えられる） |
| Ruby のバージョン | ビルドの引数 `RUBY_VERSION`（既定 `3.4.12`） |
| ruby-build のリリース | ビルドの引数 `RUBY_BUILD_VERSION`（既定 `20261023`）。Ruby のソースのチェックサムは ruby-build が検証する |
| YJIT | 組み込む（ビルドの段に Rust を入れている）。有効にするのは実行時（`ruby --yjit`、`RUBY_YJIT_ENABLE=1`。Rails 7.2 以降は既定で有効にする） |
| OpenSSL | AL2023 の OpenSSL（3.5 系）を使う。**OS の OpenSSL の更新は、この Ruby にも効く**（Ruby は OS のライブラリを読み込むため。Go と違う点） |
| 文字コード | `LANG=C.UTF-8`（Ruby の既定の外部エンコーディングを UTF-8 にする） |
| Bundler | Ruby に同梱のもの（3.4.12 では 2.6.9）。アプリの `Gemfile.lock` の `BUNDLED WITH` と違うときは、Bundler が自動でその版に切り替える |
| gem のドキュメント | 入れない（`/etc/gemrc` に `gem: --no-document`） |
| ビルド時の確認 | 最後に、`openssl`・`psych`（YAML）・`zlib`・`fiddle` が読めること、既定のエンコーディングが UTF-8 であること、YJIT が組み込まれていることを確かめる。満たさなければビルドが失敗する |

貼られた元の定義にあった `dnf update -y` は入れていない。AL2023 のリポジトリは、コンテナイメージの AL2023 のリリース（版）に固定されているため、版の中での更新はほとんど入らない。OS を新しくするときは、土台のイメージのタグを新しいリリースにしてビルドし直す（[AL2023 の運用のチップス](../../../notes/ec2-operations/amazon-linux-2023-operations-tips.md) の 2）。

## 使い方

このフォルダで実行する。

```bash
# ビルド（手元のアーキテクチャ。arm64 の Mac で約 2 分）
docker build -t al2023-ruby:3.4.12 .

# 確認
docker run --rm al2023-ruby:3.4.12                         # ruby 3.4.12 ... +PRISM [aarch64-linux]
docker run --rm al2023-ruby:3.4.12 ruby --yjit -v          # ruby 3.4.12 ... +YJIT +PRISM [aarch64-linux]

# x86_64 向け（t3a などの EC2 と同じアーキテクチャ）。エミュレーションでビルドするので、ずっと遅くなる
docker build --platform linux/amd64 -t al2023-ruby:3.4.12-amd64 .

# Ruby を上げるとき（新しいバージョンに対応した ruby-build のリリースに合わせる）
docker build --build-arg RUBY_VERSION=3.4.13 --build-arg RUBY_BUILD_VERSION=<対応したリリース> -t al2023-ruby:3.4.13 .

# AL2023 のリリースを固定するとき
docker build --build-arg AL2023_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023.12.20261026 -t al2023-ruby:3.4.12 .
```

最新のバージョンの調べ方:

| 調べるもの | 調べ方 |
|---|---|
| Ruby 3.4 系の最新 | [Ruby のリリース一覧](https://www.ruby-lang.org/ja/downloads/releases/)、または `https://cache.ruby-lang.org/pub/ruby/index.txt` |
| それに対応した ruby-build のリリース | [ruby-build のリリース](https://github.com/rbenv/ruby-build/releases)。リリースの `share/ruby-build/<Ruby のバージョン>` があれば対応している |

確認した結果（2026-10-28、arm64）:

| 項目 | 結果 |
|---|---|
| ビルドの時間 | 約 1 分 46 秒（Ruby のコンパイルは約 1 分） |
| イメージの大きさ | 396 MB（土台の AL2023 のコンテナイメージは 254 MB） |
| Ruby | `ruby 3.4.12 (2026-10-23 revision 366f5fdc00) +PRISM [aarch64-linux]` |
| OpenSSL | 3.5.8 |
| RubyGems / Bundler | 3.6.9 / 2.6.9 |
| AL2023 | `Amazon Linux release 2023.12.20261026` |

## この定義に入れていないもの

| もの | 理由・入れる場所 |
|---|---|
| アプリ（Rails）と gem | 上物。アプリのイメージ（この定義を `FROM` にする別の定義）か、リリース用インスタンスでの更新（手順 3）で入れる |
| ネイティブ拡張の gem のビルドに要るもの（`gcc`、`make`、データベースのクライアントの開発用のライブラリなど） | アプリの依存で決まる。アプリのイメージ側で入れる |
| Web サーバー、Node.js など | 下回りに含めるかは未決（[土台の構成](../../base-image-composition.md)） |
| 一般ユーザー | 今は root で動く。アプリを動かすときは、アプリのイメージ側で専用のユーザーを作る |

## EC2 の土台（AMI）に移すときの対応

この定義の手順は、EC2 Image Builder のコンポーネントや、EC2 の上での手順にほぼそのまま移せる。

| この定義 | EC2 の土台での扱い |
|---|---|
| 2 つの段に分けたビルド | EC2 では段に分けられない。ビルドに要るもの（`gcc`、Rust など）を入れたまま残すか、ビルド後に外すかを決める（ネイティブ拡張の gem をインスタンスの上で入れるなら、コンパイラーは残す） |
| `/opt/ruby` に直接入れる | rbenv を使うなら `~/.rbenv/versions/<バージョン>`（中段の CodeBuild や手元と同じ流儀）。使わないなら同じく `/opt/ruby` でよい。どちらにするかは土台の構成で決める |
| `ENV PATH`、`ENV LANG` | `/etc/profile.d/` のファイルや、systemd のユニットの `Environment=` で設定する |

EC2 Image Builder で同じ土台を作る定義の下書きは [EC2 Image Builder の定義](../../image-builder/al2023-ruby3.4/README.md)。
