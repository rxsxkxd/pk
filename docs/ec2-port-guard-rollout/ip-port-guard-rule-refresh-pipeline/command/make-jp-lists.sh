#!/bin/bash
# 踏み台サーバーで実行する。APNIC の割り当ての統計から、日本の IPv4・IPv6 の範囲の一覧（TSV）を port_guard_whitelists/ に作る
set -euo pipefail
mkdir -p port_guard_whitelists
curl -fsS --max-time 120 -o port_guard_whitelists/delegated-apnic-latest https://ftp.apnic.net/stats/apnic/delegated-apnic-latest

# 元の版（版の行の 3 番目の項目。例: 20261102）
VERSION=$(awk -F'|' '$1 ~ /^[0-9]/ && $2 == "apnic" { print $3; exit }' port_guard_whitelists/delegated-apnic-latest)

# IPv4: 先頭のアドレスと個数を、CIDR に分ける。2 列目以降は、国・割り当ての組織・状態・割り当ての日
awk -F'|' -v version="$VERSION" '
function ip2n(s,  a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
function n2ip(n) { return sprintf("%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256) }
BEGIN { print "# source: APNIC delegated-apnic-latest " version; print "# cidr\tcountry\tregistry\tstatus\tdate" }
$2 == "JP" && $3 == "ipv4" && ($7 == "allocated" || $7 == "assigned") {
  start = ip2n($4); count = $5
  while (count > 0) {
    size = 1; bits = 32
    while (size * 2 <= count && start % (size * 2) == 0) { size *= 2; bits-- }
    print n2ip(start) "/" bits "\t" $2 "\t" $1 "\t" $7 "\t" $6
    start += size; count -= size
  }
}' port_guard_whitelists/delegated-apnic-latest > port_guard_whitelists/jp-ipv4.txt

# IPv6: 先頭のアドレスと長さを、そのまま CIDR にする
awk -F'|' -v version="$VERSION" '
BEGIN { print "# source: APNIC delegated-apnic-latest " version; print "# cidr\tcountry\tregistry\tstatus\tdate" }
$2 == "JP" && $3 == "ipv6" && ($7 == "allocated" || $7 == "assigned") { print $4 "/" $5 "\t" $2 "\t" $1 "\t" $7 "\t" $6 }' \
  port_guard_whitelists/delegated-apnic-latest > port_guard_whitelists/jp-ipv6.txt

echo "APNIC の版: ${VERSION}、IPv4: $(grep -vc '^#' port_guard_whitelists/jp-ipv4.txt) 件、IPv6: $(grep -vc '^#' port_guard_whitelists/jp-ipv6.txt) 件"
