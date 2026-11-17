#!/bin/bash
# build-rules.sh・deploy-rules.sh から読み込む。ログイン中のアカウントと設定済みリージョンで宛先を決める。
# アカウントのリージョナル名前空間では、コンソールに入力した名前に -<アカウント ID>-<リージョン>-an が付く。
if [ -z "${PORT_GUARD_S3_URI:-}" ]; then
  region=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}
  account_id=$(aws sts get-caller-identity --query Account --output text)
  PORT_GUARD_S3_URI="s3://ip-port-guard-rules-${account_id}-${region}-an/port-guard/$ENVIRONMENT/current"
fi
export PORT_GUARD_S3_URI
