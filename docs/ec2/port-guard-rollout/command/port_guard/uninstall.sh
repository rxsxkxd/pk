#!/bin/bash
# port-guard のサービスを取り除く: 止めて、起動時に動かないようにし、サービスのファイルを削除する
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') uninstall"

sudo -n systemctl stop port-guard || true                       # サービスがなければ失敗するので || true
sudo -n systemctl disable port-guard || true
sudo -n iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true
sudo -n ip6tables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD || true

sudo -n rm -f /etc/systemd/system/port-guard.service                          # サービスの本体（ステップ 6）
sudo -n rm -rf /etc/systemd/system/port-guard.service.d                       # 起動時のコマンドの並び（ステップ 5 の 10-ipv4.conf・20-ipv6.conf）
sudo -n systemctl daemon-reload
sudo -n systemctl reset-failed port-guard 2>/dev/null || true   # 失敗の記録が残っていれば消す

# 確認
ls /etc/systemd/system/ | grep port-guard || echo "サービスのファイル: なし"
sudo -n iptables -w 10 -S INPUT | grep -c -- '-j PORT_GUARD' || true      # 0
