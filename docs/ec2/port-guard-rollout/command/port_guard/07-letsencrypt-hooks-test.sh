#!/bin/bash
# 置いた hook を手で動かして、80 番を通すルールが差し込まれ、削除されることを確かめる（数秒だけ 80 番が開く）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-hooks-test"

echo "-- 更新の前の hook を動かす"
sudo -n /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh
sudo -n iptables -w 10 -S INPUT | head -3                       # 1 行目に --comment port-guard-acme のルールがあること
sudo -n systemctl list-timers --all 2>/dev/null | grep port-guard-acme-close || echo "30 分後の予約: なし"

echo "-- 更新の後の hook を動かす"
sudo -n /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh
sudo -n iptables -w 10 -S INPUT | grep -c port-guard-acme || true    # 0
sudo -n ip6tables -w 10 -S INPUT | grep -c port-guard-acme || true   # 0
sudo -n systemctl list-timers --all 2>/dev/null | grep port-guard-acme-close || echo "30 分後の予約: なし（取り消された）"
sudo -n journalctl -t port-guard-acme --no-pager 2>/dev/null | tail -2   # opened ... と closed tcp/80
