#!/bin/bash
# ローカル・踏み台サーバー・CI のどこでも実行できる。ルールのデプロイ先から、前回分の IP の一覧
# （last-refresh/*.txt。前回 S3 に上げた一覧の写しで、make-refresh.sh の増減の比較の基準）を port_guard_whitelists/last-refresh/ に取る
# 使い方: PORT_GUARD_S3_URI=s3://<ルールのデプロイ先バケット>/port-guard/<環境>/current bash command/fetch-last-lists.sh
# 初回（ルールのデプロイ先に何もない）は何も取らずに終える（make-refresh.sh は「前回の記録なし」として進む）
# 個別許可の IP の一覧（allow-ipv4.txt・allow-ipv6.txt）は、ここでは取らない。正本はリポジトリの allow-lists/<環境>/
set -euo pipefail
: "${PORT_GUARD_S3_URI:?PORT_GUARD_S3_URI（例: s3://<ルールのデプロイ先バケット>/port-guard/<環境>/current）を指定する}"
LISTS=port_guard_whitelists
bucket=${PORT_GUARD_S3_URI#s3://}
bucket=${bucket%%/*}
prefix=${PORT_GUARD_S3_URI#s3://"$bucket"/}
mkdir -p "$LISTS/last-refresh"

# ルールのデプロイ先にある前回分の IP の一覧（取れなければ止まる。何もなければ空）
keys=$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix/$LISTS/last-refresh/" --query 'Contents[].Key' --output text | tr '\t' '\n' | sed '/^None$/d')

# ルールのデプロイ先のものに置き換える（手元に残っている古いものは使わない）
rm -f "$LISTS"/last-refresh/*.txt
count=0
for key in $(echo "$keys" | grep '\.txt$' || true); do
  aws s3 cp --only-show-errors "s3://$bucket/$key" "$LISTS/last-refresh/${key##*/}"
  count=$((count + 1))
done
echo "前回分の IP の一覧: ${count} 件のファイルを取った"
