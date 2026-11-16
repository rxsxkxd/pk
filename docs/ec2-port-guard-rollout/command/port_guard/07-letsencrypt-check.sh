#!/bin/bash
# Let's Encrypt の証明書の更新の仕方を確かめる（読み取りだけ。何も変えない）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-check"

echo "-- cron（certbot の行。renew か certonly か）"
sudo -n crontab -l 2>&1 | grep -n certbot || echo "root の crontab: certbot の行なし"
sudo -n sh -c 'grep -rn certbot /etc/cron.d/ /etc/crontab /etc/cron.daily/ 2>/dev/null' || echo "/etc/cron.d など: certbot の行なし"
echo "-- cron（ユーザーごとの crontab）"
sudo -n sh -c 'grep -Hn certbot /var/spool/cron/* 2>/dev/null' || echo "ユーザーの crontab: certbot の行なし"
echo "-- systemd のタイマー（certbot のもの）"
systemctl list-timers --all 2>/dev/null | grep -i certbot || echo "certbot のタイマー: なし"
echo "-- certbot の版"
sudo -n certbot --version 2>&1 || echo "certbot: 見つからない"
echo "-- 証明書と有効期限"
sudo -n certbot certificates 2>&1 || echo "証明書の一覧: 取れない"
echo "-- 証明書ごとの設定（確認の方式と、設定ずみの hook）"
sudo -n sh -c 'grep -H "authenticator\|webroot_path\|_hook" /etc/letsencrypt/renewal/*.conf' 2>&1 || echo "設定: なし"
echo "-- すでにある hook のファイル"
sudo -n sh -c 'ls -l /etc/letsencrypt/renewal-hooks/*/' 2>&1 || echo "hook のフォルダ: なし"
echo "-- 80 番の確認のパスが HTTPS へ転送されていないか（証明書ごと）"
for conf in $(sudo -n sh -c 'ls /etc/letsencrypt/renewal/*.conf' 2>/dev/null); do
  domain=$(basename "$conf" .conf)
  echo "--- ${domain}"
  curl -sS -o /dev/null -D - -m 5 -H "Host: ${domain}" "http://127.0.0.1/.well-known/acme-challenge/port-guard-check" 2>&1 | grep -iE '^(HTTP/|Location:|curl:)' || true
done
