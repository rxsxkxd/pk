#!/bin/bash
# 踏み台サーバー（と一覧更新パイプラインの CodeBuild）で実行する。S3 の公開場所から、前回上げた個別許可の IP の一覧（allow-ipv4.txt・allow-ipv6.txt）と
# 前回分の IP の一覧（last-refresh/*.txt。make-refresh.sh の増減の比較の基準）を port_guard_whitelists/ に取る
# 使い方: PORT_GUARD_S3_URI=s3://<バケット>/port-guard/<環境>/current bash command/fetch-allow-and-last-lists.sh
# 初回（S3 の公開場所に何もない）は何も取らずに終える。そのときは個別許可の IP の一覧を手で書いて置く
set -euo pipefail
: "${PORT_GUARD_S3_URI:?PORT_GUARD_S3_URI（例: s3://<バケット>/port-guard/<環境>/current）を指定する}"
LISTS=port_guard_whitelists
bucket=${PORT_GUARD_S3_URI#s3://}
bucket=${bucket%%/*}
prefix=${PORT_GUARD_S3_URI#s3://"$bucket"/}
mkdir -p "$LISTS/last-refresh"

# S3 の公開場所にあるファイルの一覧（取れなければ止まる。何もなければ空）
keys=$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix/$LISTS/" --query 'Contents[].Key' --output text | tr '\t' '\n' | sed '/^None$/d')

# 1. 前回分の IP の一覧: S3 の公開場所のものに置き換える（手元に残っている古いものは使わない）
rm -f "$LISTS"/last-refresh/*.txt
count=0
for key in $(echo "$keys" | grep "^$prefix/$LISTS/last-refresh/.*\.txt$" || true); do
  aws s3 cp --only-show-errors "s3://$bucket/$key" "$LISTS/last-refresh/${key##*/}"
  count=$((count + 1))
done
echo "前回分の IP の一覧: ${count} 件のファイルを取った"

# 2. 個別許可の IP の一覧: S3 の公開場所にあれば、それに置き換える。手元のものと違っていたら、手元のものを .before-fetch に残す
for name in allow-ipv4.txt allow-ipv6.txt; do
  if echo "$keys" | grep -qxF "$prefix/$LISTS/$name"; then
    aws s3 cp --only-show-errors "s3://$bucket/$prefix/$LISTS/$name" "$LISTS/$name.fetched"
    if [ -f "$LISTS/$name" ] && ! cmp -s "$LISTS/$name" "$LISTS/$name.fetched"; then
      mv "$LISTS/$name" "$LISTS/$name.before-fetch"
      echo "${name}: 手元のものが S3 の公開場所のものと違うので、手元のものを ${LISTS}/${name}.before-fetch に残した"
    fi
    mv "$LISTS/$name.fetched" "$LISTS/$name"
    echo "${name}: S3 の公開場所から取った（$(sed 's/#.*//' "$LISTS/$name" | awk 'NF' | wc -l | tr -d ' ') 件）"
  else
    echo "${name}: S3 の公開場所にない（初回）。手元のものを使う"
  fi
done
