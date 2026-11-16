#!/bin/bash
# 集合の今の中身を、起動時に読み込むファイルに保存し直す（05-persist-ipv6.sh の ipset save の 3 行と同じ）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') save-ipv6"

sudo -n sh -c 'ipset save port_guard_jp6 > /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_allow6 >> /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_aws6 >> /etc/port-guard/ipset-ipv6.save'

# 確認
grep -c '^add port_guard_jp6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_allow6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_aws6 ' /etc/port-guard/ipset-ipv6.save || true
