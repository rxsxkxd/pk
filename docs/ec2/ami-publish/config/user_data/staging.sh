#!/bin/bash
# 起動テンプレートの UserData（本番インスタンスの起動時に実行される）。
# 環境固有の設定・シークレットは AMI に含めず、起動時に Secrets Manager から取得して Passenger に渡す。
set -euo pipefail

TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

SECRET=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id myapp/staging/env \
  --query SecretString --output text)
echo "$SECRET" | python3 -c 'import json,sys; [print(f"passenger_env_var {k} \"{v}\";") for k,v in json.load(sys.stdin).items()]' \
  > /etc/nginx/snippets/myapp-env.conf
chmod 600 /etc/nginx/snippets/myapp-env.conf
systemctl restart nginx
