#!/bin/bash
# 踏み台サーバー（と一覧更新パイプラインの CodeBuild）で実行する。make-refresh.sh の後、人が確かめてから流す
# S3 の公開場所に、ipset 入れ替えスクリプト（refresh-ipv4.sh・refresh-ipv6.sh）、今回使った個別許可の IP の一覧、
# 前回分の IP の一覧（make-refresh.sh が今回の一覧で更新したもの。次の回の比較の基準）を上げ、最後に照合の値（SHA256SUMS）を上げる
# 使い方: PORT_GUARD_S3_URI=s3://<バケット>/port-guard/<環境>/current bash command/publish-refresh-scripts.sh
set -euo pipefail
: "${PORT_GUARD_S3_URI:?PORT_GUARD_S3_URI（例: s3://<バケット>/port-guard/<環境>/current）を指定する}"
LISTS=port_guard_whitelists

files=(
  command/port_guard/refresh-ipv4.sh
  command/port_guard/refresh-ipv6.sh
  "$LISTS/allow-ipv4.txt"
  "$LISTS/allow-ipv6.txt"
)
for name in jp-ipv4 jp-ipv6 aws-ipv4 aws-ipv6 allow-ipv4 allow-ipv6; do
  files+=("$LISTS/last-refresh/$name.txt")
done
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "${f} がない（make-refresh.sh を先に流す）"; exit 1; }
done

# 照合の値を先に作る（上げるのは最後）
sha256sum "${files[@]}" > SHA256SUMS

# 各ファイルを上げてから、最後に SHA256SUMS を上げる（取る側は、SHA256SUMS と合わない組を使わない）
for f in "${files[@]}"; do
  aws s3 cp --only-show-errors "$f" "$PORT_GUARD_S3_URI/$f"
done
aws s3 cp --only-show-errors SHA256SUMS "$PORT_GUARD_S3_URI/SHA256SUMS"

cat SHA256SUMS
echo "上げた: ${PORT_GUARD_S3_URI}/（${#files[@]} 件のファイルと SHA256SUMS）"
