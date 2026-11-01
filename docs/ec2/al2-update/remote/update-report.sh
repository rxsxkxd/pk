# update.sh が書いた、変わったパッケージの一覧を返す（Run Command の出力が切れても前の結果が残るよう、最後に送る）。
# 前置きで AU_RUN_ID が渡される。root で実行する。
set +e +o pipefail
set -u
printf 'PGSTEP %s\n' "変わったパッケージの一覧"
cat "/var/log/al2-update/$AU_RUN_ID.changes"
