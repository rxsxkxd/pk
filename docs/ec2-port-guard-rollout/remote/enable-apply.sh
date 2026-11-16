# 遮断を有効にする。先に「決めた時間の後に自動で元に戻る」予約を入れてから有効にする。
# root で実行する。前置きで PG_RUN_ID・PG_REVERT_MINUTES が渡される。
set -euo pipefail
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
step() { printf 'PGSTEP %s\n' "$1"; }
source /etc/port-guard/port-guard.conf
revert_command="iptables -D INPUT -p tcp -m multiport --dports ${PORT_GUARD_PORTS} -j PORT_GUARD"

step "今の iptables のルールを控える"
install -d -m 700 /var/lib/port-guard
iptables-save > "/var/lib/port-guard/iptables-before-${PG_RUN_ID}.txt"
kv backup "/var/lib/port-guard/iptables-before-${PG_RUN_ID}.txt"

step "自動で元に戻る予約（${PG_REVERT_MINUTES} 分後）"
if [ -d /run/systemd/system ]; then
  unit="port-guard-auto-revert-${PG_RUN_ID}"
  systemd-run --quiet --unit "$unit" --on-active="${PG_REVERT_MINUTES}min" \
    /bin/bash -c "${revert_command}; systemctl disable port-guard"
  kv revert "systemd:${unit}"
else
  # systemd がない環境（手元の再現の環境）では、切り離したプロセスで待つ
  setsid nohup bash -c "sleep $((PG_REVERT_MINUTES * 60)); ${revert_command}" >/dev/null 2>&1 < /dev/null &
  echo $! > /var/lib/port-guard/auto-revert.pid
  kv revert "pid:$!"
fi

step "有効化"
if [ -d /run/systemd/system ]; then
  systemctl enable --now port-guard
  kv unit "enabled"
else
  /usr/local/sbin/port-guard-apply
  kv unit "skipped (systemd is not running; rules were applied directly and will not survive a restart)"
fi

step "確認"
kv ports "$PORT_GUARD_PORTS"
kv jump "$(iptables -S INPUT | grep -c -- '-j PORT_GUARD' || true)"
kv chain_rules "$(iptables -S PORT_GUARD | grep -c '^-A' || true)"
count() { ipset list -t "$1" | awk -F': ' '/Number of entries/ { print $2 }'; }
kv jp_set_entries "$(count port_guard_jp)"
kv allow_set_entries "$(count port_guard_allow)"
