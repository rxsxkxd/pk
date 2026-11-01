# 入れてよいかを確かめる（sh/install.sh が install.sh の前につなげて送る。読み取りだけ）。
# 問題があれば "PG blocked=<理由>" を出して止める（終了コード 3）。root で実行する。
set -u
blocked=0
ng() { printf 'PG blocked=%s\n' "$1"; blocked=1; }
grep -q 'Amazon Linux release 2 ' /etc/system-release 2>/dev/null || ng "Amazon Linux 2 ではない"
systemctl is-active -q firewalld 2>/dev/null && ng "firewalld が動いている"
systemctl is-enabled -q firewalld 2>/dev/null && ng "firewalld が起動時に有効になっている"
systemctl is-enabled -q iptables 2>/dev/null && ng "iptables のサービスが起動時に有効になっている"
iptables -S INPUT 2>/dev/null | grep -q -- '-j PORT_GUARD' && ng "port-guard の遮断がすでに有効になっている"
rules=0
for table in filter nat mangle raw; do
  rules=$((rules + $(iptables -t "$table" -S 2>/dev/null | grep '^-A' | grep -vc PORT_GUARD)))
done
[ "$rules" = 0 ] || ng "既存の iptables のルールがある（$rules 件）"
sets=$(ipset list -n 2>/dev/null | grep -v '^port_guard_' | paste -sd, -)
[ -z "$sets" ] || ng "既存の ipset の集合がある（$sets）"
[ "$blocked" = 0 ] || exit 3
echo "PG preflight=ok"
