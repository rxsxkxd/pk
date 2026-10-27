# syntax=docker/dockerfile:1
#
# Amazon Linux 2023 に、AL2023 のパッケージの Ruby 3.4（ruby3.4）を入れたイメージ。
# ソースからはビルドしない（ruby-build で最新のパッチバージョンを入れる定義は ../al2023-ruby3.4/）。
# 説明は同じフォルダの README.md。

# AL2023 のコンテナイメージ。パッケージのリポジトリは、このイメージの AL2023 のリリースに固定される
ARG AL2023_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023

FROM ${AL2023_IMAGE}

# 入れる ruby3.4 のパッケージのバージョン。空なら、AL2023 のリリースにある最新を入れる
ARG RUBY_PACKAGE_VERSION=3.4.8

# ruby3.4 を入れると、gem（ruby3.4-rubygems）と bundle（ruby3.4-rubygem-bundler）も依存として入る
RUN dnf install -y "ruby3.4${RUBY_PACKAGE_VERSION:+-${RUBY_PACKAGE_VERSION}}" \
 && dnf clean all

# ruby / gem / bundle などの版の付かない名前を ruby3.4 に向ける（alternatives）。
# ruby 以外の道具は、入れただけでは登録されないことがあるため、なければ登録する
RUN alternatives --set ruby /usr/bin/ruby3.4 \
 && for tool in gem bundle bundler erb racc rdoc ri; do \
      if [ -x "/usr/bin/ruby3.4-${tool}" ] && [ ! -e "/usr/bin/${tool}" ]; then \
        alternatives --install "/usr/bin/${tool}" "${tool}" "/usr/bin/ruby3.4-${tool}" 34; \
      fi; \
    done

ENV LANG=C.UTF-8

# gem のドキュメントを入れない
RUN echo 'gem: --no-document' > /etc/gemrc

# 入れた Ruby の確認。バージョンが違う・拡張ライブラリが読めない場合は、ここでビルドを失敗させる
RUN ruby -v \
 && if [ -n "${RUBY_PACKAGE_VERSION}" ]; then ruby -v | grep -F "ruby ${RUBY_PACKAGE_VERSION}"; fi \
 && ruby -e 'require "openssl"; require "psych"; require "zlib"; puts OpenSSL::OPENSSL_LIBRARY_VERSION' \
 && ruby -e 'exit(Encoding.default_external == Encoding::UTF_8)' \
 && ruby -e 'if defined?(RubyVM::YJIT) then puts "YJIT is available" else puts "YJIT is not available" end' \
 && gem -v \
 && bundle -v

CMD ["ruby", "-v"]
