# 遮断を有効にできるかを確かめるための追加の確認（check.sh の後ろにつなげて送る。読み取りだけ）
if [ -f /etc/port-guard/port-guard.conf ]; then
  kv jp_min_entries "$(. /etc/port-guard/port-guard.conf; echo "${JP_MIN_ENTRIES:-1000}")"
fi
kv jp_file_entries "$(grep -cvE '^\s*(#|$)' /etc/port-guard/jp.txt 2>/dev/null || echo 0)"
if command -v ipset >/dev/null 2>&1; then
  count() { ipset list -t "$1" 2>/dev/null | awk -F': ' '/Number of entries/ { print $2 }'; }
  kv jp_set_entries "$(count port_guard_jp)"
  kv allow_set_entries "$(count port_guard_allow)"
fi
kv revert_pending "$( (systemctl list-units --all --no-legend 'port-guard-auto-revert-*' 2>/dev/null | awk '{ print $1 }'; \
  [ -f /var/lib/port-guard/auto-revert.pid ] && kill -0 "$(cat /var/lib/port-guard/auto-revert.pid)" 2>/dev/null && echo pid) | paste -sd, -)"
