# syntax=docker/dockerfile:1
#
# 海外からの確認の拠点（チェック用のクライアント）を、手元で再現するためのイメージ（Amazon Linux 2023）。
# 道具の動作の確認用。手元のコンテナからの接続は「海外の IP」にはならない。説明は同じフォルダの README.md。
#
# ビルドの文脈は outside-probe/（port-guard-probe を写すため）。compose.yaml がそう指定している。

# AL2023 のコンテナイメージ。initial-image-build の Docker の定義と同じリリース（2023.12.20261026）に digest で固定している
ARG AL2023_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:8272aee6146a36222baaf71d72ab6799770957414ac63b1e940cec58c9197188

FROM ${AL2023_IMAGE}

# 確かめる道具。コンテナのイメージは最小限なので、EC2 の AMI には最初から入っている python3 も入れる
RUN dnf install -y python3 nmap-ncat openssl \
 && dnf clean all

COPY port-guard-probe /usr/local/bin/port-guard-probe
RUN chmod 755 /usr/local/bin/port-guard-probe \
 && port-guard-probe --help > /dev/null \
 && nc --version \
 && openssl version

# docker compose exec で入って使うので、止まらずに待つ
CMD ["sleep", "infinity"]
