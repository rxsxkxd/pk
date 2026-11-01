# 確認に合格しなかったので、すぐに元に戻す（遮断のルールを消し、ユニットを無効にし、予約を取り消す）。
# 前置きで PG_REVERT が渡される（空でもよい）。
set -uo pipefail
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
source /etc/port-guard/port-guard.conf
while iptables -C INPUT -p tcp -m multiport --dports "$PORT_GUARD_PORTS" -j PORT_GUARD 2>/dev/null; do
  iptables -D INPUT -p tcp -m multiport --dports "$PORT_GUARD_PORTS" -j PORT_GUARD
done
if [ -d /run/systemd/system ]; then
  systemctl disable port-guard 2>/dev/null || true
fi
case "${PG_REVERT:-}" in
  systemd:*) systemctl stop "${PG_REVERT#systemd:}.timer" 2>/dev/null || true ;;
  pid:*) kill -- "-${PG_REVERT#pid:}" 2>/dev/null || kill "${PG_REVERT#pid:}" 2>/dev/null || true; rm -f /var/lib/port-guard/auto-revert.pid ;;
esac
kv jump "$(iptables -S INPUT | grep -c -- '-j PORT_GUARD' || true)"
