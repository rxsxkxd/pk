#!/bin/bash
# iptables のルールを入れる（ここから IPv4 の 80・443 番の遮断が効く）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 04-rules-ipv4"

# 日本の範囲が入っていなければ止める（空のまま入れると、日本からも受け付けなくなる）
[ "$(sudo -n ipset list -t port_guard_jp | awk -F': ' '/Number of entries/ { print $2 }')" -ge 1000 ] || { echo "日本の範囲が 1000 件未満なので止める"; exit 1; }

# 今のルールを控える（戻すときの手がかり）
sudo -n install -d -m 700 /var/lib/port-guard
sudo -n sh -c "iptables-save > /var/lib/port-guard/iptables-before-$(date +%Y%m%d%H%M%S).txt"

sudo -n iptables -w 10 -N PORT_GUARD
sudo -n iptables -w 10 -A PORT_GUARD -i lo -j ACCEPT
sudo -n iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT
sudo -n iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT
sudo -n iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_aws src -j ACCEPT
sudo -n iptables -w 10 -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
sudo -n iptables -w 10 -A PORT_GUARD -j DROP
sudo -n iptables -w 10 -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD

# 確認
sudo -n iptables -w 10 -S PORT_GUARD
sudo -n iptables -w 10 -S INPUT | grep -- '-j PORT_GUARD'
