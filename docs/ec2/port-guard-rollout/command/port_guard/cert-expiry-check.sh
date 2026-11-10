#!/bin/bash
# 踏み台サーバーで実行する。各稼働サーバーの 443 番が返す証明書の残り日数を表示する（読み取りだけ）
# 使い方: bash cert-expiry-check.sh <一覧のファイル> [しきい値の日数（既定 14）]
# 終了コード: 0 = すべてしきい値以上、1 = しきい値未満か、証明書を取得できない台がある
set -uo pipefail

list=$1
threshold=${2:-14}
status=0

printf '%-6s %5s  %-36s %-16s %s\n' RESULT DAYS DOMAIN ADDRESS NOT_AFTER
while read -r domain address; do
  case "$domain" in ''|\#*) continue ;; esac
  address=${address:-$domain}
  end_date=$(timeout 15 openssl s_client -connect "${address}:443" -servername "$domain" </dev/null 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -z "$end_date" ]; then
    printf '%-6s %5s  %-36s %-16s %s\n' ERROR - "$domain" "$address" "証明書を取得できない"
    status=1
    continue
  fi
  days=$(( ($(date -d "$end_date" +%s) - $(date +%s)) / 86400 ))
  if [ "$days" -lt "$threshold" ]; then
    result=WARN
    status=1
  else
    result=OK
  fi
  printf '%-6s %5s  %-36s %-16s %s\n' "$result" "$days" "$domain" "$address" "$end_date"
done < "$list"
exit "$status"
