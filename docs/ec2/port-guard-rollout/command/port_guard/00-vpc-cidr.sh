#!/bin/bash
# 対象のサーバーが入っている VPC の範囲（CIDR）を表示する（読み取りだけ）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 00-vpc-cidr"

IMDS=http://169.254.169.254   # インスタンスメタデータサービス（IMDS）の入り口。AWS が決めたアドレスで、公式の名前（DNS 名）はない
TOKEN=$(curl -fsS -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' $IMDS/latest/api/token)
MAC=$(curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $TOKEN" $IMDS/latest/meta-data/mac)
echo "IPv4 の VPC の範囲:"
curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/latest/meta-data/network/interfaces/macs/$MAC/vpc-ipv4-cidr-blocks"; echo
echo "IPv6 の VPC の範囲:"
curl -fsS -m 5 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/latest/meta-data/network/interfaces/macs/$MAC/vpc-ipv6-cidr-blocks" || echo "（なし）"; echo
