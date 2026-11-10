#!/bin/bash
# IPv4 の集合を保存し、起動時に IPv4 の集合とルールを入れ直す行をユニットの追加の設定として置く
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 05-persist-ipv4"

sudo -n install -d -m 755 /etc/port-guard
sudo -n sh -c 'ipset save port_guard_jp > /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_allow >> /etc/port-guard/ipset-ipv4.save'
sudo -n sh -c 'ipset save port_guard_aws >> /etc/port-guard/ipset-ipv4.save'

sudo -n install -d -m 755 /etc/systemd/system/port-guard.service.d
sudo -n tee /etc/systemd/system/port-guard.service.d/10-ipv4.conf > /dev/null <<'EOF'
# IPv4: 保存した集合を読み込み、ステップ 4 と同じルールを入れる
[Service]
ExecStart=/usr/sbin/ipset restore -exist -file /etc/port-guard/ipset-ipv4.save
ExecStart=-/usr/sbin/iptables -w 10 -N PORT_GUARD
ExecStart=/usr/sbin/iptables -w 10 -F PORT_GUARD
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -i lo -j ACCEPT
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_allow src -j ACCEPT
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_jp src -j ACCEPT
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -m set --match-set port_guard_aws src -j ACCEPT
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
ExecStart=/usr/sbin/iptables -w 10 -A PORT_GUARD -j DROP
ExecStart=-/usr/sbin/iptables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
ExecStart=/usr/sbin/iptables -w 10 -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD
EOF

sudo -n systemctl daemon-reload

# 確認
head -3 /etc/port-guard/ipset-ipv4.save
grep -c '^add port_guard_jp ' /etc/port-guard/ipset-ipv4.save || true    # 日本の範囲の件数（0 件のとき grep は失敗を返すので || true）
grep -c '^add port_guard_allow ' /etc/port-guard/ipset-ipv4.save || true # 許可する IP の件数
grep -c '^add port_guard_aws ' /etc/port-guard/ipset-ipv4.save || true   # AWS の東京と大阪の件数
grep -c '^ExecStart=' /etc/systemd/system/port-guard.service.d/10-ipv4.conf   # 11
