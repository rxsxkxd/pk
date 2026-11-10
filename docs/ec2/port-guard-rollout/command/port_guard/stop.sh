#!/bin/bash
# port-guard を今だけ止める: サービスを止め、カーネルの INPUT チェーンから PORT_GUARD へ飛ばすルールを削除する（80・443 番の絞り込みが外れる）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') stop"

sudo -n systemctl stop port-guard
sudo -n iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true    # ルールがなければ失敗するので || true
sudo -n ip6tables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true   # IPv6 を絞っていない台では失敗するので || true

# 確認
systemctl is-active port-guard || true                                    # inactive
sudo -n iptables -w 10 -S INPUT | grep -c -- '-j PORT_GUARD' || true      # 0
sudo -n ip6tables -w 10 -S INPUT | grep -c -- '-j PORT_GUARD' || true     # 0
