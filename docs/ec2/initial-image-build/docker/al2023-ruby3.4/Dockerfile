# syntax=docker/dockerfile:1
#
# Amazon Linux 2023 に、Ruby 3.4 の最新のパッチバージョンを入れたイメージ。
# AL2023 のパッケージ（ruby / ruby3.4）は使わず、ruby-build でソースからビルドする
# （土台の構成の Ruby の入れ方 B と同じ流儀。詳細は同じフォルダの README.md）。
#
# ビルドの段（build）でコンパイルし、実行の段にはできあがった Ruby だけを写す。
# コンパイラーや Rust などのビルドに要るものは、実行の段に残らない。

# AL2023 のコンテナイメージ。再現性が要るときは版付きのタグ（例: 2023.9.20251208.0）に固定する
ARG AL2023_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023

# ---------------------------------------------------------------------------
# ビルドの段
# ---------------------------------------------------------------------------
FROM ${AL2023_IMAGE} AS build

# 入れる Ruby のバージョンと、そのバージョンを知っている ruby-build のリリース。
# Ruby を上げるときは、新しいバージョンに対応した ruby-build のリリースに合わせて上げる
ARG RUBY_VERSION=3.4.12
ARG RUBY_BUILD_VERSION=20261023

# Ruby のビルドに要るもの
# - gcc / make / tar / gzip / patch: コンパイルと展開
# - openssl-devel / libyaml-devel / zlib-devel / libffi-devel / gmp-devel: 拡張ライブラリ
#   （openssl、psych（YAML）、zlib、fiddle、Integer の高速化）
# - rust: YJIT（JIT コンパイラー）を組み込むため。Rails 7.2 以降は YJIT があれば既定で有効にする
RUN dnf install -y \
      gcc make tar gzip patch \
      openssl-devel libyaml-devel zlib-devel libffi-devel gmp-devel \
      rust \
 && dnf clean all

# ruby-build を取得する（Ruby のソースのチェックサムは ruby-build が検証する）
RUN curl -fsSL "https://github.com/rbenv/ruby-build/archive/refs/tags/v${RUBY_BUILD_VERSION}.tar.gz" \
      | tar -xz -C /tmp \
 && /tmp/ruby-build-${RUBY_BUILD_VERSION}/install.sh \
 && rm -rf /tmp/ruby-build-${RUBY_BUILD_VERSION}

# /opt/ruby にビルドして入れる。ドキュメント（ri / rdoc）は入れない
RUN RUBY_CONFIGURE_OPTS="--disable-install-doc" ruby-build "${RUBY_VERSION}" /opt/ruby

# ---------------------------------------------------------------------------
# 実行の段
# ---------------------------------------------------------------------------
FROM ${AL2023_IMAGE}

# 拡張ライブラリが実行時に使うライブラリ（ビルドの段の *-devel に対応するもの）
RUN dnf install -y \
      openssl-libs libyaml zlib libffi gmp \
 && dnf clean all

COPY --from=build /opt/ruby /opt/ruby

ENV PATH=/opt/ruby/bin:$PATH \
    LANG=C.UTF-8

# gem のドキュメントを入れない（イメージを小さく、bundle install を速くする）
RUN echo 'gem: --no-document' > /etc/gemrc

# 入れた Ruby の確認。拡張ライブラリが読めない・YJIT がない場合は、ここでビルドを失敗させる
RUN ruby -v \
 && ruby -e 'require "openssl"; require "psych"; require "zlib"; require "fiddle"; puts OpenSSL::OPENSSL_LIBRARY_VERSION' \
 && ruby -e 'exit(Encoding.default_external == Encoding::UTF_8)' \
 && ruby -e 'exit(defined?(RubyVM::YJIT) ? true : false)' \
 && bundle -v

CMD ["ruby", "-v"]
