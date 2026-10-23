# syntax=docker/dockerfile:1
#
# 統合管理システム（Rails 5 / Ruby 2.7）のイメージの雛形
#
# アプリのリポジトリのルートに置き、ルートを文脈にしてビルドする。
# 先に docs/rr/ruby-base/Dockerfile のベースイメージを用意しておく（ECR に置くか、手元でビルドする）。
#
#   docker build -t integrated-management:local .
#
# Web（Puma）とバッチ（bin/rails runner / bin/rake）は同じイメージで、起動コマンドだけを変える
# （docs/app/integrated-management-system/09-batch-on-ecs.md）。

ARG RUBY_BUILD_IMAGE=ruby27:2.7.8-trixie
ARG RUBY_SLIM_IMAGE=ruby27:2.7.8-trixie-slim

# ---------------------------------------------------------------------------
# gems: gem を入れる（ネイティブ拡張はここで組む）
# ---------------------------------------------------------------------------
FROM ${RUBY_BUILD_IMAGE} AS gems

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      # mysql2 が使う。Debian では MariaDB Connector/C（MySQL 8.4 の caching_sha2_password に対応）
      libmariadb-dev \
    ; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /api

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test

COPY Gemfile Gemfile.lock ./
RUN set -eux; \
    bundle install --jobs "$(nproc)"; \
    rm -rf "${GEM_HOME}"/cache "${GEM_HOME}"/ruby/*/cache

# ---------------------------------------------------------------------------
# assets: アセットをプリコンパイルする
# ---------------------------------------------------------------------------
FROM gems AS assets

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

COPY . .

# 本物の秘密の値は使わない。起動時に DB へ繋ぎに行く初期化処理があると、ここで失敗する（OPEN_ITEMS.md）
RUN SECRET_KEY_BASE=dummy bin/rails assets:precompile

# ---------------------------------------------------------------------------
# runtime: 実行用
# ---------------------------------------------------------------------------
FROM ${RUBY_SLIM_IMAGE} AS runtime

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      libmariadb3 \
      # execjs が読み込み時に JavaScript の実行環境を探すため、uglifier などが本番の group にあれば要る
      nodejs \
      # 今の Dockerfile にあるため残す（mysql コマンド）。バッチなどで使っていなければ外す
      default-mysql-client \
    ; \
    rm -rf /var/lib/apt/lists/*

# RDS へ TLS で繋ぐときの CA（OS の証明書には含まれない）。database.yml の sslca で指す
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /etc/ssl/rds/global-bundle.pem

RUN useradd --system --create-home --uid 1000 --user-group rails

WORKDIR /api

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1

COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY --from=assets /api /api

RUN set -eux; \
    mkdir -p tmp/pids tmp/cache log; \
    chown -R rails:rails tmp log; \
    # 足りない共有ライブラリ（gem のネイティブ拡張が使うもの）があればここで止める
    if find /usr/local/bundle -type f -name '*.so' -exec ldd {} + | grep 'not found'; then exit 1; fi

USER rails

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
