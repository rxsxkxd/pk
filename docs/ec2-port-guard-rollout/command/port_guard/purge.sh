#!/bin/bash
# uninstall.sh の後に流す。カーネルの中の PORT_GUARD チェーンと集合、保存のファイルを消す
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') purge"

# カーネルの中のルール（INPUT から飛ばすルールを先に削除してから、チェーンを空にして消す）
sudo -n iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true
sudo -n iptables -w 10 -F PORT_GUARD || true
sudo -n iptables -w 10 -X PORT_GUARD || true
sudo -n ip6tables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true
sudo -n ip6tables -w 10 -F PORT_GUARD || true
sudo -n ip6tables -w 10 -X PORT_GUARD || true

# カーネルの中の集合（ルールから参照されていると消せないので、ルールの後に消す）
sudo -n ipset destroy port_guard_jp || true
sudo -n ipset destroy port_guard_allow || true
sudo -n ipset destroy port_guard_aws || true
sudo -n ipset destroy port_guard_jp6 || true
sudo -n ipset destroy port_guard_allow6 || true
sudo -n ipset destroy port_guard_aws6 || true

# 保存のファイル（入れる前のルールの控え /var/lib/port-guard/ は、記録として残す）
sudo -n rm -rf /etc/port-guard

# 確認
sudo -n iptables -w 10 -S | grep -c PORT_GUARD || true    # 0
sudo -n ip6tables -w 10 -S | grep -c PORT_GUARD || true   # 0
sudo -n ipset list -n | grep -c port_guard || true        # 0
