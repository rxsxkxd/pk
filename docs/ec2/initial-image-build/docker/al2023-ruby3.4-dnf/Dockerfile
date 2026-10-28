# syntax=docker/dockerfile:1
#
# Amazon Linux 2023 に、AL2023 のパッケージの Ruby 3.4（ruby3.4）を入れたイメージ。
# ソースからはビルドしない（ruby-build で最新のパッチバージョンを入れる定義は ../al2023-ruby3.4/）。
# 説明は同じフォルダの README.md。

# AL2023 のコンテナイメージ。パッケージのリポジトリは、このイメージの AL2023 のリリースに固定される。
# ruby3.4 が 3.4.8 であることを確かめたリリース（2023.12.20261026）のイメージに、digest で固定している
ARG AL2023_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:8272aee6146a36222baaf71d72ab6799770957414ac63b1e940cec58c9197188

FROM ${AL2023_IMAGE}

# 入れる ruby3.4 のパッケージのバージョン。空なら、AL2023 のリリースにある最新を入れる
ARG RUBY_PACKAGE_VERSION=3.4.8

# ruby3.4 を入れると、gem（ruby3.4-rubygems）と bundle（ruby3.4-rubygem-bundler）も依存として入る
RUN dnf install -y "ruby3.4${RUBY_PACKAGE_VERSION:+-${RUBY_PACKAGE_VERSION}}" \
 && dnf clean all

# gem / bundle などの版の付かない名前を ruby3.4 に向ける（alternatives）。
# ruby は、パッケージが alternatives の ruby（/usr/bin/ruby3.4-mri）として登録する。gem や bundle も、
# パッケージがその従属のリンクとして登録しようとするが、インストールの順番の都合で登録されない
# （2023.12.20261026 で確認）。そのため、パッケージと同じ形で従属のリンクを足す
RUN for tool in gem bundle bundler erb rdoc ri; do \
      if [ -x "/usr/bin/ruby3.4-${tool}" ] && [ ! -e "/usr/bin/${tool}" ]; then \
        alternatives --add-slave ruby /usr/bin/ruby3.4-mri "/usr/bin/${tool}" "${tool}" "/usr/bin/ruby3.4-${tool}"; \
      fi; \
    done

ENV LANG=C.UTF-8

# gem のドキュメントを入れない
RUN echo 'gem: --no-document' > /etc/gemrc

# 入れた Ruby の確認。バージョンが違う・拡張ライブラリが読めない・YJIT がない場合は、ここでビルドを失敗させる
RUN ruby -v \
 && if [ -n "${RUBY_PACKAGE_VERSION}" ]; then ruby -v | grep -F "ruby ${RUBY_PACKAGE_VERSION}"; fi \
 && ruby -e 'require "openssl"; require "psych"; require "zlib"; require "fiddle"; puts OpenSSL::OPENSSL_LIBRARY_VERSION' \
 && ruby -e 'exit(Encoding.default_external == Encoding::UTF_8)' \
 && ruby --yjit -e 'exit RubyVM::YJIT.enabled?' \
 && gem -v \
 && bundle -v

CMD ["ruby", "-v"]
