# Docker の定義: Amazon Linux 2023 と Ruby 3.4（AL2023 のパッケージ ruby3.4）

> 位置付け: [ruby-build で最新のパッチバージョンを入れる定義](../al2023-ruby3.4/README.md) と比べるための、**AL2023 のパッケージ（`dnf install ruby3.4`）で Ruby を入れる**定義。[土台の構成](../../base-image-composition.md) の Ruby の入れ方 A にあたる。
>
> 同じ入れ方の EC2 Image Builder の定義: [EC2 Image Builder の定義（AL2023 のパッケージ ruby3.4）](../../image-builder/al2023-ruby3.4-dnf/README.md)
>
> 確認日: 2026-10-28（手元の arm64 の Mac の Docker Desktop でビルドと動作を確認した）

## 入る Ruby

AL2023 のコンテナイメージ `2023.12.20261026` では、`ruby3.4` のパッケージは **3.4.8**（`3.4.8-27.amzn2023.0.7`）である。この定義は、ビルドの引数 `RUBY_PACKAGE_VERSION`（既定 `3.4.8`）でバージョンを指定して入れる（`dnf install ruby3.4-3.4.8`）。

パッケージのリポジトリは AL2023 のリリースに固定されているため、入れられるバージョンは土台のイメージの AL2023 のリリースで決まる。そのため、土台のイメージは、3.4.8 を確かめたリリースのイメージに **digest で固定**している（ビルドの引数 `AL2023_IMAGE` の既定）。

```
public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:8272aee6146a36222baaf71d72ab6799770957414ac63b1e940cec58c9197188
```

タグ `2023` だけにすると、AWS が新しいリリースを出したときにイメージが変わり（取り直しも起きる）、3.4.8 がリポジトリから外れていれば、指定したバージョンが見つからずにビルドが失敗する。

## 動かして分かったこと

| 項目 | 結果 |
|---|---|
| `ruby` | パッケージが alternatives の `ruby` として登録する。指す先は **`/usr/bin/ruby3.4-mri`**（`/usr/bin/ruby3.4` は `ruby3.4-mri` へのシンボリックリンクで、alternatives には登録されていない）。そのため、`alternatives --set ruby /usr/bin/ruby3.4` は失敗する（最初に書いた定義はここで失敗した） |
| `gem` / `bundle` など | パッケージは `ruby` の従属のリンク（`alternatives --add-slave`）として登録しようとするが、**登録されず、`/usr/bin/gem` や `/usr/bin/bundle` がない状態になる**。インストールの後に同じコマンドを実行すると登録できる（インストールの順番の都合と考えられる。AWS のユーザーガイドの「道具の登録が空になることがある」に当たる） |
| 入る道具 | `ruby3.4-gem`、`ruby3.4-bundle`、`ruby3.4-bundler`、`ruby3.4-erb`、`ruby3.4-rdoc`、`ruby3.4-ri`、`ruby3.4-syntax_suggest`。`racc` と `irb` は入らない（必要ならアプリの Gemfile で入れる） |
| 入るパッケージ | `ruby3.4`、`ruby3.4-libs`、`ruby3.4-default-gems`、`ruby3.4-rubygems`、`ruby3.4-rubygem-bundler`、`ruby3.4-rubygem-bigdecimal`・`io-console`・`json`・`psych`・`rdoc` の 10 個 |
| YJIT | **組み込まれている**（`ruby --yjit -v` で `+YJIT`） |
| 標準のライブラリ | `openssl`（OpenSSL 3.5.8）、`psych`、`zlib`、`fiddle` が読める |
| RubyGems / Bundler | 3.6.9 / 2.6.9 |
| gem の置き場所 | ルートで `gem install` すると `/usr/local/share/ruby3.4-gems`。パッケージの gem は `/usr/share/ruby3.4-gems` |
| 文字コード | `LANG` を設定しないと、既定の外部エンコーディングは US-ASCII になる。この定義では `LANG=C.UTF-8` にしている |
| イメージの大きさ | 309 MB（土台の AL2023 のコンテナイメージは 254 MB、ruby-build の定義は 396 MB） |
| ビルドの時間 | 1 分弱（大半は dnf のリポジトリのメタデータ（約 85 MB）とパッケージの取得） |

## ruby-build の定義との違い

| 項目 | この定義（AL2023 のパッケージ） | ruby-build の定義 |
|---|---|---|
| Ruby のバージョン | AL2023 のリリースにあるもの（3.4.8） | 指定したもの（3.4.12） |
| ビルドの時間 | 短い（コンパイルしない） | 長い（Ruby と、YJIT のための Rust） |
| 段の分け方 | 1 段 | 2 段（ビルドの段と実行の段） |
| Ruby のセキュリティ更新 | **OS の更新（AL2023 の新しいリリース）で入る** | Ruby のバージョンを上げてビルドし直す |
| コマンドの名前 | 本体は版付き（`ruby3.4-mri`、`ruby3.4-gem`、`ruby3.4-bundle` など）。`ruby` / `gem` / `bundle` は alternatives で向ける | `ruby` / `gem` / `bundle` |
| 置き場所 | `/usr/bin` など（OS のパッケージの置き場所） | `/opt/ruby` |
| YJIT | 組み込まれている | 組み込む |

## 定義の中身

| 手順 | 内容 |
|---|---|
| Ruby を入れる | `dnf install ruby3.4-<バージョン>`。gem と bundle は依存として入る |
| 版の付かない名前を向ける | `ruby` はパッケージが登録するので、何もしない。`gem`・`bundle`・`bundler`・`erb`・`rdoc`・`ri` は、`/usr/bin/<道具>` がなければ、パッケージと同じ形（`alternatives --add-slave ruby /usr/bin/ruby3.4-mri ...`）で `ruby` の従属のリンクとして登録する。従属のリンクなので、`ruby` を別の版に切り替えると一緒に切り替わる |
| 文字コード | `LANG=C.UTF-8` |
| gem のドキュメント | 入れない（`/etc/gemrc`） |
| ビルド時の確認 | Ruby のバージョンが指定どおりか、`openssl`・`psych`・`zlib`・`fiddle` が読めるか、既定のエンコーディングが UTF-8 か、YJIT が組み込まれているか。満たさなければビルドが失敗する |

## 使い方

このフォルダで実行する。

```bash
docker build -t al2023-ruby:3.4.8-dnf .
docker run --rm al2023-ruby:3.4.8-dnf                      # ruby 3.4.8 (2025-12-17 revision 995b59f666) +PRISM [aarch64-linux]
docker run --rm al2023-ruby:3.4.8-dnf ruby --yjit -v       # ruby 3.4.8 ... +YJIT +PRISM [aarch64-linux]

# 新しい AL2023 のリリースにある最新の ruby3.4 を入れる（イメージとバージョンの固定を外す）
docker build \
  --build-arg AL2023_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  --build-arg RUBY_PACKAGE_VERSION= \
  -t al2023-ruby:3.4-dnf .
```

## 未確認の点

| # | 点 |
|---|---|
| 1 | x86_64（`--platform linux/amd64`）でのビルド。確認したのは arm64 だけ |
| 2 | `gem` などの従属のリンクが登録されないことが、AL2023 のほかのリリースや EC2 の上でも起きるか（この定義は、登録されていれば何もしないので、どちらでも動く） |
| 3 | ネイティブ拡張の gem のビルドに、`ruby3.4-devel`・`gcc`・`make` のほかに要るパッケージがあるか |

## この定義に入れていないもの

ruby-build の定義と同じ（アプリと gem、ネイティブ拡張の gem のビルドに要るもの、一般ユーザー）。
