#!/bin/bash
# 集合の今の中身を、起動時に読み込むファイルに保存し直す（05-persist-ipv4.sh の ipset save の 3 行と同じ）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') save-ipv4"

sudo -n sh -c 'ipset save port_guard_jp > /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_allow >> /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_aws >> /etc/port-guard/ipset-ipv4.save'

# 確認
grep -c '^add port_guard_jp ' /etc/port-guard/ipset-ipv4.save || true      # 日本の範囲の件数
grep -c '^add port_guard_allow ' /etc/port-guard/ipset-ipv4.save || true   # 許可する IP アドレスの件数
grep -c '^add port_guard_aws ' /etc/port-guard/ipset-ipv4.save || true     # AWS の東京と大阪の件数
