# yum でパッケージを更新する（再起動はしない。サービスの再起動もしない）。root で実行する。
# 前置きで AU_SCOPE（security か all）、AU_EXCLUDE（除くパッケージのパターン。空白で区切る）、AU_RUN_ID が渡される。
# yum の出力はインスタンスの /var/log/al2-update/<実行の ID>.log に残す。変わったパッケージは、更新の前後の rpm -qa の差から
# <実行の ID>.changes に書き、update-report.sh が最後に返す（Run Command の出力は 24,000 文字で切れるので、長い一覧を後ろに回す）。
set -euo pipefail
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
step() { printf 'PGSTEP %s\n' "$1"; }
log_dir=/var/log/al2-update
log="$log_dir/$AU_RUN_ID.log"
changes="$log_dir/$AU_RUN_ID.changes"
packages() { rpm -qa --qf '%{NAME}.%{ARCH} %{VERSION}-%{RELEASE}\n' | sort; }

step "更新の前のパッケージの記録"
install -d -m 700 "$log_dir"
before="$log_dir/$AU_RUN_ID.before"
after="$log_dir/$AU_RUN_ID.after"
packages > "$before"

step "yum の更新"
args=(-y)
[ "$AU_SCOPE" = security ] && args+=(--security)
set -f # 除くパッケージのパターン（httpd* など）を、ファイルの名前として展開しない
for pattern in $AU_EXCLUDE; do args+=("--exclude=$pattern"); done
set +f
kv log "$log"
if ! yum "${args[@]}" update >> "$log" 2>&1; then
  tail -n 5 "$log" >&2
  exit 1
fi

step "変わったパッケージの記録"
packages > "$after"
{
  # 前にない行のうち、同じ名前が前にあれば更新、なければ新しく入ったもの（カーネルは古い版も残るので「更新」に出る）
  awk 'NR == FNR { old[$1] = ($1 in old) ? old[$1] "," $2 : $2; seen[$0] = 1; next }
       !($0 in seen) { if ($1 in old) print "PG updated=" $1 " " old[$1] " -> " $2; else print "PG installed=" $1 " " $2 }' \
    "$before" "$after"
  # 後にない名前は、取り除かれたもの（ほかのパッケージに置き換えられたもの）
  awk 'NR == FNR { now[$1] = 1; next } !($1 in now) { print "PG removed=" $1 " " $2 }' "$after" "$before"
} > "$changes"
kv updated_count "$(grep -c '^PG updated=' "$changes" || true)"
kv installed_count "$(grep -c '^PG installed=' "$changes" || true)"
kv removed_count "$(grep -c '^PG removed=' "$changes" || true)"
if [ -s "$changes" ]; then
  # yum history list の一覧の最初の数字の行が、今の更新（yum history undo <ID> で戻せる）
  kv yum_history "$(yum history list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1; exit }')"
fi
kv update_done yes
