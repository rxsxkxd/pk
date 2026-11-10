#!/bin/bash
# port-guard のサービスと、カーネルの中のルール・集合の状態を見る（読み取りだけ。何も変えない）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') status"

echo "-- サービス"
systemctl is-enabled port-guard 2>&1 || true        # enabled（起動時に動く）/ disabled（動かない）/ ファイルがなければエラー
systemctl is-active port-guard 2>&1 || true         # active（入れた）/ inactive（止まっている）/ failed（途中で失敗した）
ls -l /etc/systemd/system/port-guard.service /etc/systemd/system/port-guard.service.d/ 2>&1 || true
sudo -n journalctl -b -u port-guard --no-pager 2>&1 | tail -20 || true   # 今回の起動での、このサービスの記録

echo "-- カーネルの中のルール（INPUT から PORT_GUARD へ飛ばすルール）"
sudo -n iptables -w 10 -S INPUT | grep -- '-j PORT_GUARD' || echo "IPv4: なし"
sudo -n ip6tables -w 10 -S INPUT | grep -- '-j PORT_GUARD' || echo "IPv6: なし"

echo "-- カーネルの中の集合"
sudo -n ipset list -t 2>&1 | grep -E '^(Name|Number of entries|References):' || echo "集合: なし"
