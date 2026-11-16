#!/bin/bash
# IPv4・IPv6 で 1 つのユニットを置いて有効にする（ExecStart= はステップ 5 の追加の設定から集まる）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 06-service"

sudo -n tee /etc/systemd/system/port-guard.service > /dev/null <<'EOF'
[Unit]
Description=port-guard: accept 80/443 only from Japan and allowed addresses (IPv4 and IPv6)
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
# ExecStart= は port-guard.service.d/10-ipv4.conf・20-ipv6.conf にある（置いた分だけ動く）

[Install]
WantedBy=multi-user.target
EOF

sudo -n systemctl daemon-reload
sudo -n systemctl enable port-guard

# 確認
ls /etc/systemd/system/port-guard.service.d/        # 10-ipv4.conf（と 20-ipv6.conf）
systemctl cat port-guard | grep -c '^ExecStart='      # 11（IPv4 だけ）か 22（IPv4 と IPv6）。本体と追加の設定をまとめて表示する
systemctl is-enabled port-guard                      # enabled
