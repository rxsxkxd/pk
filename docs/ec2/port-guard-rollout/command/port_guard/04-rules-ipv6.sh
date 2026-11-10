#!/bin/bash
# ip6tables のルールを入れる（ここから IPv6 の 80・443 番の遮断が効く）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 04-rules-ipv6"

[ "$(sudo -n ipset list -t port_guard_jp6 | awk -F': ' '/Number of entries/ { print $2 }')" -ge 200 ] || { echo "日本の範囲（IPv6）が 200 件未満なので止める"; exit 1; }

sudo -n install -d -m 700 /var/lib/port-guard
sudo -n sh -c "ip6tables-save > /var/lib/port-guard/ip6tables-before-$(date +%Y%m%d%H%M%S).txt"

sudo -n ip6tables -w 10 -N PORT_GUARD
sudo -n ip6tables -w 10 -A PORT_GUARD -i lo -j ACCEPT
sudo -n ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_allow6 src -j ACCEPT
sudo -n ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_jp6 src -j ACCEPT
sudo -n ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_aws6 src -j ACCEPT
sudo -n ip6tables -w 10 -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
sudo -n ip6tables -w 10 -A PORT_GUARD -j DROP
sudo -n ip6tables -w 10 -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD

# 確認
sudo -n ip6tables -w 10 -S PORT_GUARD
sudo -n ip6tables -w 10 -S INPUT | grep -- '-j PORT_GUARD'
