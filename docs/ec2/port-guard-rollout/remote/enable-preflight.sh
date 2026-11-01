# 遮断を有効にできるかを確かめる（sh/enable.sh が enable-apply.sh の前につなげて送る。読み取りだけ）。
# 問題があれば "PG blocked=<理由>" を出して止める（終了コード 3）。root で実行する。
set -u
ng() { printf 'PG blocked=%s\n' "$1"; exit 3; }
[ -x /usr/local/sbin/port-guard-apply ] && [ -f /etc/port-guard/port-guard.conf ] || ng "port-guard が入っていない（先に install）"
iptables -S INPUT 2>/dev/null | grep -q -- '-j PORT_GUARD' && ng "遮断がすでに有効になっている"
. /etc/port-guard/port-guard.conf
case "${PORT_GUARD_PORTS:-}" in 80,443|22,80,443) ;; *) ng "ポートの設定が 80,443 か 22,80,443 ではない（${PORT_GUARD_PORTS:-なし}）" ;; esac
jp=$(grep -cvE '^\s*(#|$)' /etc/port-guard/jp.txt 2>/dev/null || echo 0)
[ "$jp" -ge "${JP_MIN_ENTRIES:-1000}" ] || ng "日本の IP の範囲の一覧が少ない（$jp 件）"
echo "PG preflight=ok"
