# SSM Agent を入れ（入っていなければ）、起動時に有効にして（起動し直して）動かす。
# root で実行する（sudo -n bash -s）
set -euo pipefail
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
step() { printf 'PGSTEP %s\n' "$1"; }

step "SSM Agent のインストール"
if rpm -q amazon-ssm-agent >/dev/null 2>&1; then
  kv installed "already"
else
  yum install -y -q amazon-ssm-agent
  kv installed "now"
fi
kv agent_version "$(rpm -q --qf '%{VERSION}' amazon-ssm-agent)"

step "起動時の有効化と起動"
if [ -d /run/systemd/system ]; then
  systemctl enable amazon-ssm-agent
  # 認証情報を取り直させるため、動いていても起動し直す
  systemctl restart amazon-ssm-agent
  sleep 3
  v=$(systemctl is-enabled amazon-ssm-agent 2>/dev/null || true); kv agent_enabled "${v:-none}"
  v=$(systemctl is-active amazon-ssm-agent 2>/dev/null || true); kv agent_active "${v:-unknown}"
else
  kv agent_enabled "skipped (systemd is not running)"
  kv agent_active "skipped (systemd is not running)"
fi

step "AWS の窓口への接続の診断"
if command -v ssm-cli >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  failed=$(ssm-cli get-diagnostics --output table 2>/dev/null | grep -c 'Failed' || true)
  kv diagnostics_failed "$failed"
else
  kv diagnostics_failed "skipped"
fi
