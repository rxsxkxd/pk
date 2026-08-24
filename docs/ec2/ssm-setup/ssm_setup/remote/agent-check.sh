# SSM Agent まわりの今の状態を確かめる（読み取りだけ）。結果を "PG <キー>=<値>" の行で返す。
# root で実行する（sudo -n bash -s）
set -u
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
unit_enabled() { local v; v=$(systemctl is-enabled "$1" 2>/dev/null); echo "${v:-none}"; }
unit_active() { local v; v=$(systemctl is-active "$1" 2>/dev/null); echo "${v:-unknown}"; }

kv os "$(head -1 /etc/system-release 2>/dev/null || echo unknown)"
kv systemd "$([ -d /run/systemd/system ] && echo running || echo not-running)"
if rpm -q amazon-ssm-agent >/dev/null 2>&1; then
  kv agent_installed yes
  kv agent_version "$(rpm -q --qf '%{VERSION}' amazon-ssm-agent)"
else
  kv agent_installed no
  kv agent_version ""
fi
kv agent_enabled "$(unit_enabled amazon-ssm-agent)"
kv agent_active "$(unit_active amazon-ssm-agent)"

# インスタンスのメタデータ（IMDSv2）: インスタンスプロファイルの有無と、リージョン
token=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)
if [ -n "$token" ]; then
  kv imds yes
  meta() { curl -s -m 2 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true; }
  code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' -H "X-aws-ec2-metadata-token: $token" \
    http://169.254.169.254/latest/meta-data/iam/info 2>/dev/null || true)
  kv instance_profile "$([ "$code" = 200 ] && echo yes || echo no)"
  region=$(meta placement/region)
  kv region "$region"
  if [ -n "$region" ]; then
    # 応答のコードは問わない（000 なら届いていない）
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "https://ssm.${region}.amazonaws.com/" 2>/dev/null || true)
    kv ssm_endpoint "$([ -n "$code" ] && [ "$code" != 000 ] && echo reachable || echo unreachable)"
  fi
else
  kv imds no
fi
