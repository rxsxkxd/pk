# 確認に合格したので、自動で元に戻る予約を取り消して確定する。前置きで PG_REVERT が渡される。
set -euo pipefail
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
case "$PG_REVERT" in
  systemd:*) systemctl stop "${PG_REVERT#systemd:}.timer" 2>/dev/null || true ;;
  pid:*) kill -- "-${PG_REVERT#pid:}" 2>/dev/null || kill "${PG_REVERT#pid:}" 2>/dev/null || true; rm -f /var/lib/port-guard/auto-revert.pid ;;
esac
# 予約のプロセス（プロセスのグループ）が消えたことを確かめる（最大 5 秒待つ）
if [ "${PG_REVERT#pid:}" != "$PG_REVERT" ]; then
  for _ in 1 2 3 4 5; do
    pgrep -g "${PG_REVERT#pid:}" >/dev/null 2>&1 || break
    sleep 1
  done
  kv revert_alive "$(pgrep -g "${PG_REVERT#pid:}" >/dev/null 2>&1 && echo yes || echo no)"
fi
kv cancelled "$PG_REVERT"
kv jump "$(iptables -S INPUT | grep -c -- '-j PORT_GUARD' || true)"
