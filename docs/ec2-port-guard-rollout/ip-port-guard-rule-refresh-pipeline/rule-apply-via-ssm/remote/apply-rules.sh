#!/bin/bash
# ルールの適用スクリプト。apply_rules.rb が SSM の Run Command（AWS-RunShellScript）で適用対象サーバーに送り、root で流れる。
# ルールのデプロイ先から照合の値（SHA256SUMS）と ipset 入れ替えスクリプトを取り、照合してから ipset 入れ替えスクリプトを流す。
# apply_rules.rb が前に付ける値:
#   PG_S3_URI      ルールのデプロイ先（例: s3://ip-port-guard-rules-<アカウント ID>-<リージョン>-an/port-guard/staging/current）
#   PG_REGION      ルールのデプロイ先バケットのリージョン
#   PG_APPLY_IPV6  1 なら refresh-ipv6.sh も流す
set -euo pipefail
echo "== $(hostname) $(date '+%F %T') apply-rules"
: "${PG_S3_URI:?PG_S3_URI がない}"
: "${PG_REGION:?PG_REGION がない}"
command -v aws > /dev/null || { echo "PG blocked=aws-cli-not-found（AWS CLI がない）"; exit 1; }

files=(command/port_guard/refresh-ipv4.sh)
[ "${PG_APPLY_IPV6:-0}" = 1 ] && files+=(command/port_guard/refresh-ipv6.sh)

work=$(mktemp -d /tmp/port-guard-rules.XXXXXX)
trap 'rm -rf "$work"' EXIT
cd "$work"

# 1. 照合の値を先に取り、そのあと ipset 入れ替えスクリプトを取る（ルールのデプロイ先へは照合の値が最後に上がるので、上げている途中なら照合で合わない）
aws s3 cp --region "$PG_REGION" --only-show-errors "$PG_S3_URI/SHA256SUMS" SHA256SUMS
for f in "${files[@]}"; do
  mkdir -p "$(dirname "$f")"
  aws s3 cp --region "$PG_REGION" --only-show-errors "$PG_S3_URI/$f" "$f"
done

# 2. 照合する（取ったファイルの行だけ。合わなければ何も変えずに止まる）
: > check
for f in "${files[@]}"; do
  awk -v f="$f" '$2 == f' SHA256SUMS >> check
  grep -q "  $f\$" check || { echo "PG blocked=not-in-sha256sums（SHA256SUMS に ${f} がない）"; exit 1; }
done
sha256sum -c check || { echo "PG blocked=checksum-mismatch（照合の値と合わない。ルールを上げている途中なら、終わってから流し直す）"; exit 1; }

# 3. ipset 入れ替えスクリプトを流す（一時の集合に入れて件数を確かめてから ipset swap。port-guard を入れていない台では、何も変えずに止まる）
for f in "${files[@]}"; do
  bash "$f"
done

# 4. 適用の記録フォルダに、流した ipset 入れ替えスクリプトの写しと日時を残す
install -d -m 755 /var/lib/port-guard/rules
for f in "${files[@]}"; do
  install -m 644 "$f" "/var/lib/port-guard/rules/$(basename "$f")"
done
install -m 644 SHA256SUMS /var/lib/port-guard/rules/SHA256SUMS
echo "$(date '+%F %T') ${PG_S3_URI}" > /var/lib/port-guard/rules/last-applied
echo "PG result=applied"
