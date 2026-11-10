#!/bin/bash
# 踏み台サーバーで実行する。AWS の IP アドレスの範囲の一覧（ip-ranges.json）から、東京・大阪のリージョンの範囲の一覧（TSV）を port_guard_whitelists/ に作る
set -euo pipefail
mkdir -p port_guard_whitelists
curl -fsS --max-time 120 -o port_guard_whitelists/ip-ranges.json https://ip-ranges.amazonaws.com/ip-ranges.json

# 取り出す条件
REGIONS='ap-northeast-1 ap-northeast-3'          # 東京・大阪
SERVICE='AMAZON'                                 # AWS の全部のサービスを含む区分
EXCLUDE_BORDER_GROUPS='ap-northeast-1-tpe-1'     # 東京リージョンの中でも日本の外にあるもの（台北のローカルゾーン）

# 元の版（ip-ranges.json の createDate）
CREATED=$(awk -F'"' '$2 == "createDate" { print $4; exit }' port_guard_whitelists/ip-ranges.json)

# IPv4（"ip_prefix"）。1 つの範囲は { から } までの数行で、1 行に 1 つの項目がある
awk -F'"' -v key=ip_prefix -v regions="$REGIONS" -v service="$SERVICE" -v exclude="$EXCLUDE_BORDER_GROUPS" -v created="$CREATED" '
BEGIN { n = split(regions, a, " "); for (i = 1; i <= n; i++) R[a[i]] = 1
        n = split(exclude, b, " "); for (i = 1; i <= n; i++) X[b[i]] = 1
        print "# source: AWS ip-ranges.json createDate " created; print "# cidr\tregion\tservice\tnetwork_border_group" }
$2 == key { p = $4 }
$2 == "region" { r = $4 }
$2 == "service" { s = $4 }
$2 == "network_border_group" { g = $4 }
/^[[:space:]]*}/ { if (p != "" && (r in R) && s == service && !(g in X)) print p "\t" r "\t" s "\t" g; p = r = s = g = "" }' \
  port_guard_whitelists/ip-ranges.json > port_guard_whitelists/aws-ipv4.txt

# IPv6（"ipv6_prefix"）
awk -F'"' -v key=ipv6_prefix -v regions="$REGIONS" -v service="$SERVICE" -v exclude="$EXCLUDE_BORDER_GROUPS" -v created="$CREATED" '
BEGIN { n = split(regions, a, " "); for (i = 1; i <= n; i++) R[a[i]] = 1
        n = split(exclude, b, " "); for (i = 1; i <= n; i++) X[b[i]] = 1
        print "# source: AWS ip-ranges.json createDate " created; print "# cidr\tregion\tservice\tnetwork_border_group" }
$2 == key { p = $4 }
$2 == "region" { r = $4 }
$2 == "service" { s = $4 }
$2 == "network_border_group" { g = $4 }
/^[[:space:]]*}/ { if (p != "" && (r in R) && s == service && !(g in X)) print p "\t" r "\t" s "\t" g; p = r = s = g = "" }' \
  port_guard_whitelists/ip-ranges.json > port_guard_whitelists/aws-ipv6.txt

echo "ip-ranges.json の版: ${CREATED}、IPv4: $(grep -vc '^#' port_guard_whitelists/aws-ipv4.txt) 件、IPv6: $(grep -vc '^#' port_guard_whitelists/aws-ipv6.txt) 件"
