# syntax=docker/dockerfile:1
#
# Amazon Linux 2023 に、mise で Ruby 3 系の最新を入れたイメージ（試すためのもの）。
# Ruby はコンパイルせず、mise が jdx/ruby から取得するビルド済みのもの（バイナリ）を使う。
# 説明は同じフォルダの README.md。

# AL2023 のコンテナイメージ。../al2023-ruby3.4-dnf/ と同じリリース（2023.12.20261026）に digest で固定している
ARG AL2023_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:8272aee6146a36222baaf71d72ab6799770957414ac63b1e940cec58c9197188

FROM ${AL2023_IMAGE}

# mise のバージョン（空なら、mise のリポジトリにある最新）と、入れる Ruby のバージョン。
# Ruby は既定で 3 系の最新に追従する（mise の設定に "3" と書かれ、作り直すたびにその時点の 3 系の最新が入る）。
# 決まったバージョンにするときは、ビルドの引数で 3.4.12 のように指定する
ARG MISE_VERSION=2026.10.21
ARG RUBY_VERSION=3

# mise の dnf のリポジトリ（mise の公式。パッケージは GPG の署名で確かめる）を足し、mise を入れる
RUN curl -fsSL https://mise.jdx.dev/rpm/mise.repo -o /etc/yum.repos.d/mise.repo \
 && dnf install -y "mise${MISE_VERSION:+-${MISE_VERSION}}" \
 && dnf clean all

# mise の置き場所をイメージの中の 1 か所（/mise）にまとめ、shims を PATH に足す。
# MISE_RUBY_COMPILE=false: ビルド済みの Ruby だけを使う（見つからなければ、コンパイルに切り替えずに失敗する）
ENV MISE_DATA_DIR=/mise \
    MISE_CONFIG_DIR=/mise \
    MISE_CACHE_DIR=/mise/cache \
    MISE_RUBY_COMPILE=false \
    PATH=/mise/shims:$PATH \
    LANG=C.UTF-8

# Ruby を入れ、全体の既定（/mise/config.toml）にする。取得したアーカイブ（約 90 MB）はイメージに残さない。
# 注意: Docker のビルドのキャッシュが残っていると、この手順は実行し直されず、新しい Ruby が出ても入らない。
# 追従させるときは --no-cache（または --no-cache-filter）で作り直す
RUN mise use --global "ruby@${RUBY_VERSION}" \
 && rm -rf /mise/cache

# gem のドキュメントを入れない
RUN echo 'gem: --no-document' > /etc/gemrc

# 試すための表示（失敗にはしない）: どこに入ったか、OpenSSL などを OS から使うか同梱のものを使うか、証明書の置き場所
RUN set -x; \
    mise --version; \
    mise ls; \
    ruby_dir="$(mise where ruby)"; \
    ls "${ruby_dir}" "${ruby_dir}/lib"; \
    ruby -ropenssl -e 'puts "OpenSSL (build): #{OpenSSL::OPENSSL_VERSION}"; puts "OpenSSL (runtime): #{OpenSSL::OPENSSL_LIBRARY_VERSION}"; puts "default cert file: #{OpenSSL::X509::DEFAULT_CERT_FILE}"'; \
    if command -v ldd >/dev/null 2>&1; then \
      ldd "${ruby_dir}/bin/ruby"; \
      for feature in openssl psych zlib fiddle; do \
        ldd "$(ruby -r"${feature}" -e "puts \$LOADED_FEATURES.grep(%r{/${feature}\\.so\\z}).first")"; \
      done; \
    fi; \
    true

# 入れた Ruby の確認。バージョンが違う・拡張ライブラリが読めない・YJIT がない場合は、ここでビルドを失敗させる
# （RUBY_VERSION が 3 なら「ruby 3」で始まるか、3.4.12 なら「ruby 3.4.12」で始まるかを見る）
RUN ruby -v \
 && ruby -v | grep -E "^ruby ${RUBY_VERSION//./\\.}[. ]" \
 && ruby -e 'require "openssl"; require "psych"; require "zlib"; require "fiddle"' \
 && ruby -e 'exit(Encoding.default_external == Encoding::UTF_8)' \
 && ruby --yjit -e 'exit RubyVM::YJIT.enabled?' \
 && gem -v \
 && bundle -v

CMD ["ruby", "-v"]
