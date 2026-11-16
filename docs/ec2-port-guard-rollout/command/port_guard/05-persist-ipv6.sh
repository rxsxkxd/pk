#!/bin/bash
# IPv6 の集合を保存し、起動時に IPv6 の集合とルールを入れ直す行をユニットの追加の設定として置く
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 05-persist-ipv6"

sudo -n install -d -m 755 /etc/port-guard
sudo -n sh -c 'ipset save port_guard_jp6 > /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_allow6 >> /etc/port-guard/ipset-ipv6.save'
sudo -n sh -c 'ipset save port_guard_aws6 >> /etc/port-guard/ipset-ipv6.save'

sudo -n install -d -m 755 /etc/systemd/system/port-guard.service.d
sudo -n tee /etc/systemd/system/port-guard.service.d/20-ipv6.conf > /dev/null <<'EOF'
# IPv6: 保存した集合を読み込み、ステップ 4 と同じルールを入れる
[Service]
ExecStart=/usr/sbin/ipset restore -exist -file /etc/port-guard/ipset-ipv6.save
ExecStart=-/usr/sbin/ip6tables -w 10 -N PORT_GUARD
ExecStart=/usr/sbin/ip6tables -w 10 -F PORT_GUARD
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -i lo -j ACCEPT
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_allow6 src -j ACCEPT
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_jp6 src -j ACCEPT
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -m set --match-set port_guard_aws6 src -j ACCEPT
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -m limit --limit 10/min -j LOG --log-prefix "port-guard drop: "
ExecStart=/usr/sbin/ip6tables -w 10 -A PORT_GUARD -j DROP
ExecStart=-/usr/sbin/ip6tables -w 10 -D INPUT -p tcp -m multiport --dports 80,443 -j PORT_GUARD
ExecStart=/usr/sbin/ip6tables -w 10 -I INPUT 1 -p tcp -m multiport --dports 80,443 -j PORT_GUARD
EOF

sudo -n systemctl daemon-reload

# 確認
head -3 /etc/port-guard/ipset-ipv6.save
grep -c '^add port_guard_jp6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_allow6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^add port_guard_aws6 ' /etc/port-guard/ipset-ipv6.save || true
grep -c '^ExecStart=' /etc/systemd/system/port-guard.service.d/20-ipv6.conf   # 11
