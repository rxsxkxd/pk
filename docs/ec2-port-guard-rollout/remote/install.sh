# ipset を入れ、port-guard の設定・スクリプト・ユニットを置き、日本の IP の範囲を取って集合を作る。
# 遮断はまだ効かせない（ユニットは enable しない、INPUT からの参照は足さない）。
# root で実行する（sudo -n bash -s）。前置きで PG_* の変数が渡される。
set -euo pipefail
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
step() { printf 'PGSTEP %s\n' "$1"; }

step "パッケージ（ipset、python3）"
yum install -y -q ipset python3
v=$(systemctl is-enabled ipset 2>/dev/null || true)
kv ipset_unit_enabled "${v:-none}"

step "ファイルの配置"
install -d -m 755 /etc/port-guard
printf 'PORT_GUARD_PORTS=%s\nJP_MIN_ENTRIES=%s\n' "$PG_PORTS" "$PG_JP_MIN_ENTRIES" > /etc/port-guard/port-guard.conf
printf '%s' "$PG_ALLOW_B64" | base64 -d > /etc/port-guard/allow.txt
printf '%s' "$PG_APPLY_B64" | base64 -d > /usr/local/sbin/port-guard-apply
printf '%s' "$PG_UPDATE_JP_B64" | base64 -d > /usr/local/sbin/port-guard-update-jp
printf '%s' "$PG_SERVICE_B64" | base64 -d > /etc/systemd/system/port-guard.service
chmod 644 /etc/port-guard/port-guard.conf /etc/port-guard/allow.txt /etc/systemd/system/port-guard.service
chmod 755 /usr/local/sbin/port-guard-apply /usr/local/sbin/port-guard-update-jp
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  kv unit "registered"
else
  kv unit "skipped (systemd is not running)"
fi

step "日本の IP の範囲の取得と、集合の作成"
/usr/local/sbin/port-guard-update-jp

step "確認"
count() { ipset list -t "$1" | awk -F': ' '/Number of entries/ { print $2 }'; }
kv jp_entries "$(count port_guard_jp)"
kv allow_entries "$(count port_guard_allow)"
kv port_guard_jump "$(iptables -S INPUT | grep -c -- '-j PORT_GUARD' || true)"
v=$(systemctl is-enabled port-guard 2>/dev/null || true)
kv port_guard_unit_enabled "${v:-none}"
for ip in $PG_CHECK_IN_JP; do
  if ipset test port_guard_jp "$ip" 2>/dev/null; then kv "check_in_jp_$ip" yes; else kv "check_in_jp_$ip" no; fi
done
for ip in $PG_CHECK_OUTSIDE; do
  jp=no; allow=no
  ipset test port_guard_jp "$ip" 2>/dev/null && jp=yes
  ipset test port_guard_allow "$ip" 2>/dev/null && allow=yes
  kv "check_outside_$ip" "jp=$jp,allow=$allow"
done
