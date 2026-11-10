#!/bin/bash
# IPv4 の空の集合を作る（日本の範囲と、許可する IP）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 02-sets-ipv4"

sudo -n ipset create -exist port_guard_jp hash:net family inet maxelem 65536
sudo -n ipset create -exist port_guard_allow hash:net family inet maxelem 65536
sudo -n ipset create -exist port_guard_aws hash:net family inet maxelem 65536

# 確認
sudo -n ipset list -t port_guard_jp
sudo -n ipset list -t port_guard_allow
sudo -n ipset list -t port_guard_aws
