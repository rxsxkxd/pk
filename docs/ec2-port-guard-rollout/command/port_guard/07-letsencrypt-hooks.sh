#!/bin/bash
# Let's Encrypt の証明書の更新の間だけ、TCP の 80 番をどこからでも通す hook を置く
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-hooks"

sudo -n install -d -m 755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post

# 80 番を通すルールを削除する（更新の後の hook と、30 分後の予約から呼ばれる。何度流してもよい）
sudo -n tee /usr/local/sbin/port-guard-acme-close > /dev/null <<'EOF'
#!/bin/bash
# port-guard: Let's Encrypt の確認のために差し込んだ「TCP の 80 番は通す」ルールを、カーネルの INPUT チェーンから削除する
# 同じ条件のルールを、削除できなくなるまで削除する（何かの理由で 2 つ入っていても残さない）
while /usr/sbin/iptables -w 10 -D INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null; do :; done
while /usr/sbin/ip6tables -w 10 -D INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null; do :; done
# 残っていないかを確かめて、記録に残す（journalctl -t port-guard-acme で見られる）
if /usr/sbin/iptables -w 10 -C INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null; then
  /usr/bin/logger -t port-guard-acme "WARNING: tcp/80 rule (IPv4) is still in INPUT"
else
  /usr/bin/logger -t port-guard-acme "closed tcp/80"
fi
exit 0
EOF
sudo -n chmod 755 /usr/local/sbin/port-guard-acme-close

# 更新の前: 80 番を通すルールを差し込み、30 分後に削除する予約を入れる
sudo -n tee /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh > /dev/null <<'EOF'
#!/bin/bash
# port-guard: Let's Encrypt の確認の間だけ、カーネルの INPUT チェーンの一番上に「TCP の 80 番は、どこからでも通す」ルールを差し込む
# すでに差し込まれていれば、差し込まない（二重に入れない）
/usr/sbin/iptables -w 10 -C INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null \
  || /usr/sbin/iptables -w 10 -I INPUT 1 -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT
/usr/sbin/ip6tables -w 10 -C INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null \
  || /usr/sbin/ip6tables -w 10 -I INPUT 1 -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT
# 30 分後に削除する予約（前の予約が残っていれば、取り消してから入れ直す）
/usr/bin/systemctl stop port-guard-acme-close.timer 2>/dev/null
/usr/bin/systemctl reset-failed port-guard-acme-close.service 2>/dev/null
/usr/bin/systemd-run --unit=port-guard-acme-close --on-active=30min /usr/local/sbin/port-guard-acme-close
# 差し込めたかを確かめて、記録に残す（journalctl -t port-guard-acme で見られる）
if /usr/sbin/iptables -w 10 -C INPUT -p tcp --dport 80 -m comment --comment port-guard-acme -j ACCEPT 2>/dev/null; then
  /usr/bin/logger -t port-guard-acme "opened tcp/80 for Let's Encrypt (closes after renewal, or in 30 minutes at the latest)"
else
  /usr/bin/logger -t port-guard-acme "WARNING: failed to open tcp/80 (IPv4). The renewal may fail"
fi
# 失敗しても certbot の更新は続けさせる（開けられなかったときは、確認が通らず更新が失敗するだけで、今と同じ）
exit 0
EOF
sudo -n chmod 755 /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh

# 更新の後: 80 番を通すルールを削除し、30 分後の予約を取り消す
sudo -n tee /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh > /dev/null <<'EOF'
#!/bin/bash
# port-guard: Let's Encrypt の確認が終わったので、差し込んだ 80 番のルールを削除し、30 分後の予約を取り消す
/usr/local/sbin/port-guard-acme-close
/usr/bin/systemctl stop port-guard-acme-close.timer 2>/dev/null
exit 0
EOF
sudo -n chmod 755 /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh

# 確認
sudo -n ls -l /usr/local/sbin/port-guard-acme-close /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh
sudo -n bash -n /usr/local/sbin/port-guard-acme-close
sudo -n bash -n /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh
sudo -n bash -n /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh
