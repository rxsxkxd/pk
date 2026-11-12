#!/bin/bash
# SSM Agent の状態を見る（インスタンスの中の操作。読み取りだけ）。
# 稼働サーバーの上で bash で動く（root でなければ、root が要るところだけ sudo -n）。AWS の API は呼ばない。
# 稼働サーバーへの届け方（SSH など）は ssm-setup の範囲外。例: ssh centos@<稼働サーバー> 'bash' < instance/agent-check.sh
# 結果は人が読む形で出す。最後の「見立て」に、次に行うことを出す。
set -u
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo -n"
IMDS=http://169.254.169.254   # インスタンスのメタデータの入り口（AWS が決めたアドレス）

echo "== $(hostname) $(date '+%F %T') agent-check"

os=$(head -1 /etc/system-release 2>/dev/null || echo 不明)
echo "OS: $os"
if [ -d /run/systemd/system ]; then systemd=動いている; else systemd=動いていない; fi
echo "systemd: $systemd"

if rpm -q amazon-ssm-agent >/dev/null 2>&1; then
  installed=yes
  echo "SSM Agent: 入っている（$(rpm -q --qf '%{VERSION}' amazon-ssm-agent)）"
else
  installed=no
  echo "SSM Agent: 入っていない"
fi
enabled=$(systemctl is-enabled amazon-ssm-agent 2>/dev/null || true)
active=$(systemctl is-active amazon-ssm-agent 2>/dev/null || true)
echo "起動時の有効化: ${enabled:-なし}"
echo "動作: ${active:-不明}"

# インスタンスのメタデータ（IMDSv2）: インスタンスプロファイルが見えるか、リージョン
token=$(curl -s -m 5 -X PUT "$IMDS/latest/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)
profile=不明
endpoint=不明
if [ -z "$token" ]; then
  echo "インスタンスのメタデータ: 届かない（EC2 ではない、または止めている）"
else
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "X-aws-ec2-metadata-token: $token" \
    "$IMDS/latest/meta-data/iam/info" 2>/dev/null || true)
  if [ "$code" = 200 ]; then profile=見える; else profile=見えない; fi
  echo "インスタンスプロファイル: $profile"
  region=$(curl -s -m 5 -H "X-aws-ec2-metadata-token: $token" "$IMDS/latest/meta-data/placement/region" 2>/dev/null || true)
  echo "リージョン: ${region:-不明}"
  if [ -n "$region" ]; then
    # 応答のコードは問わない（000 なら届いていない。それ以外の数字なら届いている）
    endpoint=届く
    for name in ssm ssmmessages ec2messages; do
      code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$name.$region.amazonaws.com/" 2>/dev/null || true)
      if [ -z "$code" ] || [ "$code" = 000 ]; then result=届かない; endpoint=届かない; else result="届く（$code）"; fi
      echo "AWS の窓口 $name: $result"
    done
  fi
fi

echo "-- SSM Agent の記録の最後"
$SUDO tail -n 20 /var/log/amazon/ssm/amazon-ssm-agent.log 2>/dev/null || echo "（読めない）"

# 見立て: 次に行うこと
case "$os" in
  "Amazon Linux release 2 "*) ;;
  *) echo "見立て: Amazon Linux 2 ではない。手で直す"; exit 0 ;;
esac
if [ "$profile" = 見えない ]; then
  echo "見立て: インスタンスプロファイルが見えていない。ssm_role.rb を見直す（agent-install.sh では直らない）"
elif [ "$endpoint" = 届かない ]; then
  echo "見立て: AWS の窓口への送信の 443 番が通っていない。手で直す（agent-install.sh では直らない）"
elif [ "$installed" = no ]; then
  echo "見立て: agent-install.sh で入れる"
elif [ "$enabled" != enabled ] || [ "$active" != active ]; then
  echo "見立て: agent-install.sh で有効にして起動する"
else
  echo "見立て: 動いている。Online でないなら、agent-install.sh で起動し直す（権限を拾い直させる）"
fi
