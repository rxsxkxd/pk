#!/bin/bash
# ローカル・踏み台サーバー・CI のどこでも、同じコマンドで実行する。build-rules.sh の表示（件数・増減）を人が確かめてから流す
# build-rules.sh が作業フォルダに作った ipset 入れ替えスクリプトなどを、S3 の公開場所に上げる（照合の値 SHA256SUMS を最後）
# 使い方: PORT_GUARD_S3_URI=s3://<公開バケット>/port-guard/<環境>/current bash ip-port-guard-rule-refresh-pipeline/deploy-rules.sh <環境>
# 要るもの: bash・AWS CLI（S3 の公開場所に書く権限）
set -euo pipefail
ENVIRONMENT=${1:?環境の名前を指定する（build-rules.sh に渡したものと同じ）}
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
[ -d "$WORK" ] || { echo "作業フォルダ ${WORK} がない（build-rules.sh ${ENVIRONMENT} を先に流す）"; exit 1; }

# build-rules.sh の後にリポジトリの個別許可の IP の一覧が変わっていたら止まる（確かめた内容と違うものを上げない）
for name in allow-ipv4.txt allow-ipv6.txt; do
  cmp -s "$ALLOW_LISTS/$name" "$WORK/port_guard_whitelists/$name" || { echo "${name}: リポジトリのものと、build-rules.sh が使ったものが違うので止める（build-rules.sh を流し直す）"; exit 1; }
done

cd "$WORK"
echo "== 環境: ${ENVIRONMENT}、作業フォルダ: ${WORK}"
bash "$ROLLOUT/command/publish-refresh-scripts.sh"
