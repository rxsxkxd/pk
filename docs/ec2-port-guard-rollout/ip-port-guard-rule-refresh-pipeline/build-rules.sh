#!/bin/bash
# ローカル・踏み台サーバー・CI のどこでも、同じコマンドで実行する（リポジトリの ec2-port-guard-rollout/ の下がそのままあればよい）
# 公開元の IP の一覧（APNIC・AWS）を取り、ipset に入れる IP の一覧を作り、件数と前回分との増減を確かめて、
# ipset 入れ替えスクリプト（refresh-ipv4.sh・refresh-ipv6.sh）を作業フォルダに作る。S3 には何も上げない（上げるのは deploy-rules.sh）
# 使い方: PORT_GUARD_S3_URI=s3://<公開バケット>/port-guard/<環境>/current bash ip-port-guard-rule-refresh-pipeline/build-rules.sh <環境>
#   増減の基準で止まり、内容を確かめたうえで進めるときは FORCE=1 を付ける
#   作業フォルダは、既定でこのフォルダの work/<環境>/（PORT_GUARD_WORK_DIR で変えられる）
# 要るもの: bash・curl・awk・AWS CLI（S3 の公開場所を読む権限）
set -euo pipefail
ENVIRONMENT=${1:?環境の名前を指定する（development・staging・production のどれか。allow-lists/ の下のフォルダの名前）}
: "${PORT_GUARD_S3_URI:?PORT_GUARD_S3_URI（例: s3://<公開バケット>/port-guard/<環境>/current）を指定する}"
HERE=$(cd "$(dirname "$0")" && pwd)
ROLLOUT=$(cd "$HERE/.." && pwd)
ALLOW_LISTS=$ROLLOUT/allow-lists/$ENVIRONMENT
WORK=${PORT_GUARD_WORK_DIR:-$HERE/work/$ENVIRONMENT}

# 環境の取り違えを防ぐ: S3 の公開場所が、指定した環境のものであること
case "$PORT_GUARD_S3_URI" in
  */"$ENVIRONMENT"/current) ;;
  *) echo "PORT_GUARD_S3_URI（${PORT_GUARD_S3_URI}）が /${ENVIRONMENT}/current で終わっていないので止める"; exit 1 ;;
esac
for name in allow-ipv4.txt allow-ipv6.txt; do
  [ -f "$ALLOW_LISTS/$name" ] || { echo "個別許可の IP の一覧 ${ALLOW_LISTS}/${name} がない（allow-lists/README.md を見て置く）"; exit 1; }
done

mkdir -p "$WORK/port_guard_whitelists"
cd "$WORK"
echo "== 環境: ${ENVIRONMENT}、作業フォルダ: ${WORK}"
# 前の回に作ったものを消す（途中で止まったときに、前の回の ipset 入れ替えスクリプトが残って上げられないようにする）
rm -f command/port_guard/refresh-ipv4.sh command/port_guard/refresh-ipv6.sh SHA256SUMS

echo "== 1. 公開元の IP の一覧を取り、日本・AWS（東京・大阪）の IP の一覧を作る"
bash "$ROLLOUT/command/make-jp-lists.sh"
bash "$ROLLOUT/command/make-aws-lists.sh"

echo "== 2. 個別許可の IP の一覧を、リポジトリ（allow-lists/${ENVIRONMENT}/）から写す"
cp "$ALLOW_LISTS/allow-ipv4.txt" "$ALLOW_LISTS/allow-ipv6.txt" port_guard_whitelists/

echo "== 3. 前回分の IP の一覧（増減の比較の基準）を、S3 の公開場所から取る"
bash "$ROLLOUT/command/fetch-last-lists.sh"

echo "== 4. 件数と前回分との増減を確かめ、ipset 入れ替えスクリプトを作る"
FORCE="${FORCE:-0}" bash "$ROLLOUT/command/make-refresh.sh"

echo "== できた。上の件数・増減を確かめてから、deploy-rules.sh ${ENVIRONMENT} で S3 の公開場所に上げる"
