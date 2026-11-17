#!/bin/bash
# ローカル・踏み台サーバー・CI のどこでも、同じコマンドで実行する（このフォルダだけがあればよい）
# 公開元の IP の一覧（APNIC・AWS）を取り、ipset に入れる IP の一覧を作り、ipset 入れ替えスクリプトを作業フォルダ work/<環境>/ に作る
# S3 には何も上げない（上げるのは deploy-rules.sh）
# 使い方: bash build-rules.sh <環境>      （環境は development・staging・production。増減の基準で止まったあと進めるときは FORCE=1）
set -euo pipefail
ENVIRONMENT=${1:?環境の名前を指定する（development・staging・production）}
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/command/set-s3-uri.sh"
WORK=${PORT_GUARD_WORK_DIR:-$HERE/work/$ENVIRONMENT}
mkdir -p "$WORK/port_guard_whitelists"
cd "$WORK"

# 1. 公開元の IP の一覧を取り、日本・AWS（東京・大阪）の IP の一覧を作る
bash "$HERE/command/make-jp-lists.sh"
bash "$HERE/command/make-aws-lists.sh"
# 2. 個別許可の IP の一覧を、allow-lists/<環境>/ から写す
cp "$HERE/allow-lists/$ENVIRONMENT/allow-ipv4.txt" "$HERE/allow-lists/$ENVIRONMENT/allow-ipv6.txt" port_guard_whitelists/
# 3. 前回分の IP の一覧（増減の比較の基準）を、S3 の公開場所から取る
bash "$HERE/command/fetch-last-lists.sh"
# 4. 件数と前回分との増減を確かめ、ipset 入れ替えスクリプトを作る
FORCE="${FORCE:-0}" bash "$HERE/command/make-refresh.sh"
