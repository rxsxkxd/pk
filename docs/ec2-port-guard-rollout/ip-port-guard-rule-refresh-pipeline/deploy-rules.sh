#!/bin/bash
# ローカル・踏み台サーバー・CI のどこでも、同じコマンドで実行する。build-rules.sh の表示（件数・増減）を人が確かめてから流す
# build-rules.sh が作業フォルダ work/<環境>/ に作ったものを、S3 の公開場所に上げる（照合の値 SHA256SUMS を最後）
# 使い方: bash deploy-rules.sh <環境>      （AWS CLI でログインしている人の権限で上げる）
set -euo pipefail
ENVIRONMENT=${1:?環境の名前を指定する（development・staging・production）}
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/command/set-s3-uri.sh"
cd "${PORT_GUARD_WORK_DIR:-$HERE/work/$ENVIRONMENT}"
bash "$HERE/command/publish-refresh-scripts.sh"
