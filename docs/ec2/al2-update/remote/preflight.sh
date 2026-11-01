# 更新してよいかを確かめる（rb/check.rb・rb/update.rb が、ほかのスクリプトの前につなげて送る。読み取りだけ）。
# 問題があれば "PG blocked=<理由>" を出して止める（終了コード 3）。root で実行する。
set -u
blocked=0
ng() { printf 'PG blocked=%s\n' "$1"; blocked=1; }
grep -q 'Amazon Linux release 2 ' /etc/system-release 2>/dev/null || ng "Amazon Linux 2 ではない"
command -v yum >/dev/null 2>&1 || ng "yum のコマンドがない"
if [ -f /var/run/yum.pid ] && kill -0 "$(cat /var/run/yum.pid 2>/dev/null)" 2>/dev/null; then
  ng "yum がほかで動いている（PID $(cat /var/run/yum.pid)。起動の直後なら cloud-init の更新かもしれない）"
fi
for dir in / /var; do
  free=$(df -Pm "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }')
  [ "${free:-0}" -ge 500 ] || ng "$dir の空きが少ない（${free:-不明} MB。500 MB 以上が要る）"
done
[ "$blocked" = 0 ] || exit 3
echo "PG preflight=ok"
