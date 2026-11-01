# インスタンスの今の状態を確かめる（読み取りだけ）。結果を "PG <キー>=<値>" の行で返す。
# root で実行する（sudo -n bash -s）
set -u
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
installed() { rpm -q "$1" >/dev/null 2>&1 && echo yes || echo no; }
unit_enabled() { local v; v=$(systemctl is-enabled "$1" 2>/dev/null); echo "${v:-none}"; }
unit_active() { local v; v=$(systemctl is-active "$1" 2>/dev/null); echo "${v:-unknown}"; }

kv os "$(head -1 /etc/system-release 2>/dev/null || echo unknown)"
kv systemd "$([ -d /run/systemd/system ] && echo running || echo not-running)"
kv firewalld_installed "$(installed firewalld)"
kv firewalld_enabled "$(unit_enabled firewalld)"
kv firewalld_active "$(unit_active firewalld)"
kv iptables_services_installed "$(installed iptables-services)"
kv iptables_enabled "$(unit_enabled iptables)"
kv ipset_installed "$(command -v ipset >/dev/null 2>&1 && echo yes || echo no)"
if command -v ipset >/dev/null 2>&1; then
  kv ipset_sets "$(ipset list -n 2>/dev/null | paste -sd, -)"
else
  kv ipset_sets ""
fi
other_rules=0
for table in filter nat mangle raw; do
  n=$(iptables -t "$table" -S 2>/dev/null | grep '^-A' | grep -vc 'PORT_GUARD' || true)
  other_rules=$((other_rules + n))
done
kv iptables_other_rules "$other_rules"
kv port_guard_jump "$(iptables -S INPUT 2>/dev/null | grep -c -- '-j PORT_GUARD' || true)"
kv port_guard_installed "$([ -x /usr/local/sbin/port-guard-apply ] && echo yes || echo no)"
kv python3 "$(command -v python3 >/dev/null 2>&1 && echo yes || echo no)"
kv docker_active "$(unit_active docker)"
# 前回置いた port-guard の設定（再実行のときに、何が変わるかを示すため）
if [ -f /etc/port-guard/port-guard.conf ]; then
  kv ports_current "$(. /etc/port-guard/port-guard.conf; echo "${PORT_GUARD_PORTS:-}")"
fi
if [ -f /etc/port-guard/allow.txt ]; then
  kv allow_current "$(sed 's/#.*//' /etc/port-guard/allow.txt | awk 'NF { print $1 }' | paste -sd, -)"
fi
