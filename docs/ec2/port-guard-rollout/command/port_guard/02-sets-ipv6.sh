#!/bin/bash
# IPv6 の空の集合を作る（日本の範囲と、許可する IP）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 02-sets-ipv6"

sudo -n ipset create -exist port_guard_jp6 hash:net family inet6 maxelem 65536
sudo -n ipset create -exist port_guard_allow6 hash:net family inet6 maxelem 65536
sudo -n ipset create -exist port_guard_aws6 hash:net family inet6 maxelem 65536

# 確認
sudo -n ipset list -t port_guard_jp6
sudo -n ipset list -t port_guard_allow6
sudo -n ipset list -t port_guard_aws6
