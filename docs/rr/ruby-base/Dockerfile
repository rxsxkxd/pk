# syntax=docker/dockerfile:1
#
# Ruby 2.7.8 のベースイメージ（Debian 13 trixie、システムの OpenSSL 3 を使う）
#
# 公式の ruby:2.7 のイメージは bullseye までしかなく、更新も止まっているため自前で組む。
# 公式の ruby / ruby-slim と同じ使い方ができるように、ターゲットを 2 つ用意する。
#
#   build: Ruby ＋ コンパイラと開発用ヘッダー（bundle install でネイティブ拡張を組む段で使う）
#   slim : Ruby ＋ 実行に要るライブラリだけ（アプリの実行用イメージの土台）
#
#   docker build --target build -t ruby27:2.7.8-trixie      docs/rr/ruby-base
#   docker build --target slim  -t ruby27:2.7.8-trixie-slim docs/rr/ruby-base
#
# 設計と理由は docs/rr/DESIGN.md。

# Docker Hub の回数の上限を避けるため、ECR Public のミラーから取る
ARG DEBIAN_IMAGE=public.ecr.aws/docker/library/debian:trixie-slim

# ---------------------------------------------------------------------------
# build: Ruby をソースから組む
# ---------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS build

ARG RUBY_VERSION=2.7.8
# https://www.ruby-lang.org/en/news/2023/03/30/ruby-2-7-8-released/ の tar.xz の値
ARG RUBY_SHA256=f22f662da504d49ce2080e446e4bea7008cee11d5ec4858fc69000d0e5b1d7fb
# Ruby 2.7 同梱の openssl 拡張（2.1 系）は OpenSSL 3 で組めないため、
# Ruby 2.7 に対応した openssl gem の 3.3 系の拡張に差し替える（DESIGN.md の 4.1）
ARG OPENSSL_GEM_VERSION=3.3.3
# https://rubygems.org/api/v1/versions/openssl.json の sha
ARG OPENSSL_GEM_SHA256=d46902138f2987c13122fab826030a11c2bb9b8a16394215cbfc5062c5e2d335
# Ruby 2.7 に対応する最後の版（3.5 以降は Ruby 3.0 以上）
ARG RUBYGEMS_VERSION=3.4.22
# アプリの Gemfile.lock の BUNDLED WITH に合わせる（Rails 5.0 / 5.1 なら 1.17.3）
ARG BUNDLER_VERSION=2.4.22

ENV LANG=C.UTF-8

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      libffi-dev \
      libgmp-dev \
      libssl-dev \
      libyaml-dev \
      pkg-config \
      xz-utils \
      zlib1g-dev \
    ; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir -p /usr/local/etc; \
    echo 'gem: --no-document' > /usr/local/etc/gemrc; \
    \
    mkdir -p /usr/src/ruby /usr/src/openssl-gem; \
    cd /usr/src; \
    curl -fsSL -o ruby.tar.xz "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.xz"; \
    echo "${RUBY_SHA256}  ruby.tar.xz" | sha256sum -c -; \
    curl -fsSL -o openssl.gem "https://rubygems.org/downloads/openssl-${OPENSSL_GEM_VERSION}.gem"; \
    echo "${OPENSSL_GEM_SHA256}  openssl.gem" | sha256sum -c -; \
    tar -xJf ruby.tar.xz -C ruby --strip-components=1; \
    tar -xOf openssl.gem data.tar.gz | tar -xzf - -C openssl-gem; \
    \
    # openssl 拡張の差し替え。gem の lib/ は Ruby のソースでは ext/openssl/lib/ に置く。
    # ext/digest の extconf が古い ext/openssl/deprecation.rb を読むため、それだけ残す
    cp ruby/ext/openssl/deprecation.rb /usr/src/deprecation.rb; \
    rm -rf ruby/ext/openssl; \
    cp -r openssl-gem/ext/openssl ruby/ext/openssl; \
    cp -r openssl-gem/lib ruby/ext/openssl/lib; \
    mv /usr/src/deprecation.rb ruby/ext/openssl/deprecation.rb; \
    \
    cd ruby; \
    # GCC 14 で既定でエラーになった古い書き方（暗黙の関数宣言、互換でないポインタの型など）を
    # 警告に戻す。ここで入れた CFLAGS は RbConfig に残り、bundle install で組む古い gem にも効く
    ./configure \
      --prefix=/usr/local \
      --enable-shared \
      --disable-install-doc \
      CFLAGS='-O2 -fpermissive' \
    ; \
    make -j"$(nproc)"; \
    make install; \
    cd /; \
    rm -rf /usr/src/ruby /usr/src/openssl-gem /usr/src/ruby.tar.xz /usr/src/openssl.gem; \
    \
    gem update --system "${RUBYGEMS_VERSION}"; \
    gem install bundler -v "${BUNDLER_VERSION}"; \
    rm -rf /root/.gem /usr/local/lib/ruby/gems/*/cache/*; \
    \
    ruby -v; \
    ruby -ropenssl -e 'puts OpenSSL::OPENSSL_LIBRARY_VERSION, "openssl ext #{OpenSSL::VERSION}"'; \
    gem -v; \
    bundle -v

# 公式の ruby のイメージと同じ置き場所にそろえる（今の Dockerfile をそのまま載せ替えられるように）
ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_APP_CONFIG=${GEM_HOME} \
    BUNDLE_SILENCE_ROOT_WARNING=1 \
    PATH=${GEM_HOME}/bin:${PATH}
RUN mkdir -p "${GEM_HOME}" && chmod 1777 "${GEM_HOME}"

CMD ["irb"]

# ---------------------------------------------------------------------------
# slim: 実行に要るライブラリと、build で組んだ Ruby だけ
# ---------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS slim

ENV LANG=C.UTF-8

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libffi8 \
      libgmp10 \
      libssl3t64 \
      libyaml-0-2 \
      tzdata \
      zlib1g \
    ; \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local /usr/local

ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_APP_CONFIG=${GEM_HOME} \
    BUNDLE_SILENCE_ROOT_WARNING=1 \
    PATH=${GEM_HOME}/bin:${PATH}

# 足りない共有ライブラリがあればここで止める
RUN set -eux; \
    ldconfig; \
    if find /usr/local -type f -name '*.so*' -exec ldd {} + | grep 'not found'; then exit 1; fi; \
    ruby -ropenssl -ryaml -rzlib -rfiddle -e 'puts RUBY_DESCRIPTION, OpenSSL::OPENSSL_LIBRARY_VERSION'

CMD ["irb"]
