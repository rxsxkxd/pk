# syntax=docker/dockerfile:1
#
# 今の構成（Amazon Linux 2・Apache・Passenger・Rails 4.2・Ruby 2.7.7）に近いインスタンスを、
# 手元で再現するためのイメージ。port-guard-rollout（国内だけに絞る設定）を試す相手にする。
# 説明は同じフォルダの README.md。

# 再現性のため、2026-10-28 に取得したイメージに digest で固定している
ARG AL2_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2@sha256:b8109ddd2eade72af451e2f5928de467fd9f623ae67e85a132489d67928988e7

FROM ${AL2_IMAGE}

# 今のインスタンスに合わせる版
ARG HTTPD_VERSION=2.4.56
# AL2 の mod_http2 は Apache と別の版の番号で出ている。最新（2.4.69）は Apache 2.4.69 を求めるので、
# 2.4.56 と組み合わせられる版を指定する（今のインスタンスの版は rpm -q mod_http2 で確かめる）
ARG MOD_HTTP2_VERSION=1.15.19-1.amzn2.0.2
ARG RUBY_VERSION=2.7.7
ARG PASSENGER_VERSION=6.0.18
# 道具の版（Ruby 2.7 で使える最後の Bundler と RubyGems）
ARG RBENV_RELEASE=1.3.2
ARG RUBY_BUILD_VERSION=20261023
ARG BUNDLER_VERSION=2.4.22
ARG RUBYGEMS_VERSION=3.4.22
# アプリと rbenv の持ち主（今のインスタンスと同じ）
ARG APP_USER=centos

# 今のインスタンスに近づける。iptables のコマンドと SSH のサーバーは入れ、
# SSM Agent・ipset・iptables-services・firewalld は入れない（今のインスタンスは SSH で直接入っていて、SSM Agent はない見込み）
RUN yum install -y \
      sudo cronie iptables iproute procps-ng shadow-utils hostname which findutils \
      tar gzip bzip2 curl openssl \
      openssh-server \
 && yum clean all \
 && ssh-keygen -A \
 && sed -i -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
           -e 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

# Apache（今のインスタンスと同じ版。HTTPD_VERSION と MOD_HTTP2_VERSION を空にすると、リポジトリの最新）
RUN v="${HTTPD_VERSION:+-${HTTPD_VERSION}}" \
 && h2="${MOD_HTTP2_VERSION:+-${MOD_HTTP2_VERSION}}" \
 && yum install -y "httpd${v}" "httpd-tools${v}" "httpd-devel${v}" "mod_ssl${v}" "mod_http2${h2}" \
 && yum clean all

# Ruby と Passenger のビルドに要るもの
RUN yum install -y \
      gcc gcc-c++ make patch xz \
      openssl-devel zlib-devel readline-devel libyaml-devel libffi-devel \
      libcurl-devel apr-devel apr-util-devel \
 && yum clean all

# アプリと rbenv の持ち主のユーザー（sudo をパスワードなしで使える）
RUN useradd -m "${APP_USER}" \
 && echo "${APP_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${APP_USER}" \
 && chmod 440 "/etc/sudoers.d/${APP_USER}" \
 && chmod 711 "/home/${APP_USER}" \
 && install -d -m 700 -o "${APP_USER}" -g "${APP_USER}" "/home/${APP_USER}/.ssh"

USER ${APP_USER}
ENV HOME=/home/${APP_USER}
WORKDIR /home/${APP_USER}

# rbenv と ruby-build で Ruby を入れる（今のインスタンスと同じ /home/<ユーザー>/.rbenv）
RUN mkdir -p .rbenv/plugins/ruby-build \
 && curl -fsSL "https://github.com/rbenv/rbenv/archive/refs/tags/v${RBENV_RELEASE}.tar.gz" \
      | tar -xz --strip-components=1 -C .rbenv \
 && curl -fsSL "https://github.com/rbenv/ruby-build/archive/refs/tags/v${RUBY_BUILD_VERSION}.tar.gz" \
      | tar -xz --strip-components=1 -C .rbenv/plugins/ruby-build \
 && RUBY_CONFIGURE_OPTS="--disable-install-doc" .rbenv/bin/rbenv install "${RUBY_VERSION}" \
 && .rbenv/bin/rbenv global "${RUBY_VERSION}" \
 && printf '%s\n' 'export PATH="$HOME/.rbenv/bin:$PATH"' 'eval "$(rbenv init - bash)"' >> .bashrc

ENV PATH=/home/${APP_USER}/.rbenv/shims:/home/${APP_USER}/.rbenv/bin:$PATH

# RubyGems と Bundler を Ruby 2.7 で使える最後の版に、Passenger を今のインスタンスと同じ版に
RUN gem update --system "${RUBYGEMS_VERSION}" --no-document \
 && gem install bundler -v "${BUNDLER_VERSION}" --no-document \
 && gem install passenger -v "${PASSENGER_VERSION}" --no-document \
 && rbenv rehash \
 && passenger-install-apache2-module --auto --languages ruby

# アプリ（Rails 4.2 の最小のアプリ）
COPY --chown=${APP_USER}:${APP_USER} app/ /home/${APP_USER}/app/
# arm64（手元の Mac）では、ビルド済みの nokogiri が AL2 の glibc（2.26）より新しい glibc を求めるので、
# ソースからビルドする（x86_64 のビルド済みのものは AL2 で動くので、そのまま使う）
RUN cd app \
 && if [ "$(uname -m)" = "aarch64" ]; then bundle config set --local force_ruby_platform true; fi \
 && bundle _${BUNDLER_VERSION}_ install --jobs 4 \
 && mkdir -p log tmp public

USER root
ENV HOME=/root

# Apache の設定（Passenger の読み込みは、今のインスタンスの設定と同じ形のパスにする）
COPY httpd/passenger.conf.template /tmp/passenger.conf.template
COPY httpd/app.conf /etc/httpd/conf.d/app.conf
RUN sed -e "s|@APP_USER@|${APP_USER}|g" \
        -e "s|@RUBY_VERSION@|${RUBY_VERSION}|g" \
        -e "s|@RUBY_API_VERSION@|${RUBY_VERSION%.*}.0|g" \
        -e "s|@PASSENGER_VERSION@|${PASSENGER_VERSION}|g" \
        /tmp/passenger.conf.template > /etc/httpd/conf.d/passenger.conf \
 && rm /tmp/passenger.conf.template \
 && sed -i "s|@APP_USER@|${APP_USER}|g" /etc/httpd/conf.d/app.conf \
 && if [ ! -f /etc/pki/tls/certs/localhost.crt ]; then \
      openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=localhost" \
        -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt; \
    fi \
 && httpd -t

COPY entrypoint.sh /usr/local/sbin/entrypoint.sh
RUN chmod 755 /usr/local/sbin/entrypoint.sh

ENV APP_USER=${APP_USER}

EXPOSE 22 80 443
CMD ["/usr/local/sbin/entrypoint.sh"]
