# 更新される予定のパッケージを "PG pending=<名前>.<アーキテクチャ> <版>" の行で返す（読み取りだけ。
# ただし、パッケージの情報を取るので yum のキャッシュは新しくなる）。root で実行する。
# 前置きで AU_SCOPE（security か all）が渡される。除くパッケージ（AU_EXCLUDE）はここでは付けずに全部を返し、
# 除くかどうかは作業者の PC の側（rb/）で分けて表示する。
set +e +o pipefail
set -u
kv() { printf 'PG %s=%s\n' "$1" "$2"; }
printf 'PGSTEP %s\n' "更新される予定のパッケージの一覧"

security=()
[ "$AU_SCOPE" = security ] && security=(--security)
# AL2 の bash（4.2）は、set -u で空の配列を "${a[@]}" と書くと止まるので、この形で書く
list=$(yum -q ${security[@]+"${security[@]}"} check-update 2>/dev/null)
code=$?
# yum check-update の終了コード: 0 = 更新なし、100 = 更新あり、それ以外 = 失敗
case "$code" in
  0 | 100) ;;
  *) printf 'yum check-update が失敗した（終了コード %s）\n' "$code" >&2; exit 1 ;;
esac

# 名前が長いと、yum は 1 つのパッケージを 2 行に折り返す（名前だけの行は、次の行とつなぐ）。
# 「Obsoleting Packages」から後は、置き換えられるパッケージの一覧なので読まない
pending=$(printf '%s\n' "$list" | awk '
  /^Obsoleting Packages/ { exit }
  NF == 1 { wrapped = $1; next }
  wrapped != "" { $0 = wrapped " " $0; wrapped = "" }
  NF >= 3 && $1 ~ /\./ && $2 ~ /^[0-9]/ { print $1 " " $2 }')
kv pending_count "$(printf '%s\n' "$pending" | grep -c .)"
printf '%s\n' "$pending" | sed -n 's/^./PG pending=&/p'
