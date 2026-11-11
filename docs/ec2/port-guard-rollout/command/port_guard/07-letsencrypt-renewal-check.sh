#!/bin/bash
# 実際の証明書の更新の後に、hook が 80 番を開けて閉じたか、証明書が新しくなったか、httpd が新しい証明書を返しているかを確かめる（読み取りだけ。何も変えない）
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') 07-letsencrypt-renewal-check"

echo "-- cron の記録（certbot の行。cron が certbot を動かした時刻）"
sudo -n sh -c 'grep -H certbot /var/log/cron*' 2>/dev/null || echo "/var/log/cron: certbot の行なし"

echo "-- hook の記録（journalctl。開けた時刻と閉じた時刻）"
sudo -n journalctl -t port-guard-acme --no-pager -o short-iso 2>&1 | tail -20 || echo "journalctl: 見られない"
echo "-- hook の記録（/var/log/messages。再起動で journalctl から消えたとき用）"
sudo -n sh -c 'grep -H port-guard-acme /var/log/messages*' 2>/dev/null || echo "/var/log/messages: port-guard-acme の行なし"

# certbot certificates を流すと certbot のログが 1 つ増えるので、certbot のログは先に見る
echo "-- certbot のログ（20 日以内に書かれたもの。新しい順）"
sudo -n find /var/log/letsencrypt -type f -mtime -20 -exec ls -lt --time-style=long-iso {} + 2>&1 || echo "/var/log/letsencrypt: 見られない"
echo "-- certbot のログの中の hook の名前とエラー（20 日以内に書かれたもの）"
sudo -n find /var/log/letsencrypt -type f -mtime -20 -exec grep -Hi 'port-guard\|error' {} + 2>/dev/null | tail -40 || echo "該当の行なし"

echo "-- 証明書と有効期限（certbot certificates）"
sudo -n certbot certificates 2>&1 || echo "証明書の一覧: 取れない"

echo "-- 証明書ごとの、ファイルのリンク先・期限と、443 番が返す証明書"
for conf in $(sudo -n sh -c 'ls /etc/letsencrypt/renewal/*.conf' 2>/dev/null); do
  name=$(basename "$conf" .conf)
  echo "--- ${name}"
  sudo -n ls -l --time-style=long-iso "/etc/letsencrypt/live/${name}/" 2>&1 | grep -- '->' || true
  echo "ファイル（live/${name}/cert.pem）:"
  sudo -n openssl x509 -noout -serial -dates -in "/etc/letsencrypt/live/${name}/cert.pem" 2>&1 || true
  echo "443 番が返す証明書（127.0.0.1:443、SNI は ${name}）:"
  echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "${name}" 2>/dev/null | openssl x509 -noout -serial -dates 2>&1 || echo "443 番から取れない"
done
