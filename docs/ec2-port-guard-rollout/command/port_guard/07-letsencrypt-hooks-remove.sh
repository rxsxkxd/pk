#!/bin/bash
# Let's Encrypt の hook を取り除く（差し込まれたままの 80 番のルールがあれば、先に削除する）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-hooks-remove"

sudo -n /usr/local/sbin/port-guard-acme-close || true
sudo -n systemctl stop port-guard-acme-close.timer 2>/dev/null || true
sudo -n rm -f /etc/letsencrypt/renewal-hooks/pre/port-guard-open-80.sh /etc/letsencrypt/renewal-hooks/post/port-guard-close-80.sh /usr/local/sbin/port-guard-acme-close

# 確認
sudo -n sh -c 'ls /etc/letsencrypt/renewal-hooks/*/' 2>&1 | grep -c port-guard || true   # 0
