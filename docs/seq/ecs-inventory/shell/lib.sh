# 棚卸しツールのシェル版で共通に使う部分。各ツールの shell/<ツール>.sh が source する。
# 正本は docs/seq/_common/shell/lib.sh。各ツールにあるのは sync-common.sh で写したものなので、直接編集しない。
#
# ツール側で定義するもの:
#   TOOL            使い方の表示に使うコマンド名
#   SNAPSHOT_USAGE  一覧取得（snapshot）のオプションの書き方
#   DETAIL_KINDS    詳細取得（detail）の種類と、当てはまるレコード種別。"種類:種別,種別 種類:種別" の形
#   snapshot_main   一覧取得。引数は snapshot のオプション。レコードを 1 行ずつ出す
#   detail_<種類>   詳細取得。引数はレコード（JSON）。結果を JSON で出す。
#                   失敗したら aws のエラー文を stderr に出して 1 を返す
set -euo pipefail

# 混み合っているときは CLI が自分で送る速さを落とす
export AWS_RETRY_MODE=${AWS_RETRY_MODE:-adaptive}
export AWS_PAGER=""

die() { echo "$*" >&2; exit 1; }

for cmd in aws jq; do
  command -v "$cmd" >/dev/null || die "$cmd が必要です"
done

lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/cache"

# 詳細取得のときだけ --interval の値になる
interval=0
# 一覧取得のときに、どのレコードにも付ける共通の項目（account_id, region, collected_at）
common='{}'

# jq の共通の定義。ツール側の jq プログラムの前に付けて使う
# shellcheck disable=SC2016
jq_lib='
  # CLI の日時（ISO 8601 のタイムゾーン付き、または設定によってはエポック秒）を UTC の秒単位にそろえる
  def utc_iso:
    if . == null then null
    elif type == "number" then floor | todate
    else
      (capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$") // null) as $m
      | if $m == null then .
        else
          ($m.tz | if . == "Z" then 0
                   else (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)
                   end) as $offset
          | ($m.dt + "Z" | fromdateiso8601) - $offset | todate
        end
    end;
  # エポック秒の文字列（SQS などの属性）を UTC にする
  def epoch_iso: if . == null then null else tonumber | floor | todate end;
  # タグの配列（Key/Value または key/value）をオブジェクトにする
  def tags_object: (. // []) | map({key: (.Key // .key), value: (.Value // .value)}) | from_entries;
  # 共通の項目を付けてレコードにする
  def record($type; $fields; $errors): {record_type: $type} + $common + $fields + {errors: $errors};
  def record($type; $fields): record($type; $fields; []);
'

current_region() {
  echo "${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
}

# CLI のエラー文から 操作名・コード・本文 を取り出す（$1: 取り出せないときの操作名, $2: stderr のファイル）
cli_error() {
  jq -nc --arg op "$1" --arg err "$(<"$2")" '
    ($err | capture("\\((?<code>[^)]+)\\) when calling the (?<operation>[A-Za-z0-9]+) operation( \\(reached max retries: [0-9]+\\))?: (?<message>.*)"))
      // {operation: $op, code: "Unknown", message: $err}
    | {operation, code, message}'
}

# 配列を n 件ずつ空白区切りの 1 行にする
chunks() {
  jq -r --argjson n "$1" '. as $a | range(0; length; $n) | $a[.:. + $n] | join(" ")'
}

# 一覧取得で使う呼び出し
aws_json() {
  aws "$@" --output json </dev/null
}

# 詳細取得で使う呼び出し。1 回ごとに間隔を空ける
aws_paced() {
  sleep "$interval"
  aws_json "$@"
}

# 「設定が無い」ことをエラーで返す API 用。$1 のエラーコード（空白区切り）なら null を出す
aws_paced_or_null() {
  local codes=$1 err out code
  shift
  err=$(mktemp "$work/err.XXXXXX")
  if out=$(aws_paced "$@" 2>"$err"); then
    # 設定が何も無いと、CLI は何も出さないことがある（get-bucket-versioning など）
    [ -n "$out" ] || out='{}'
    echo "$out"
  else
    code=$(cli_error "" "$err" | jq -r '.code')
    case " $codes " in
      *" $code "*) echo null ;;
      *) cat "$err" >&2; return 1 ;;
    esac
  fi
}

# 同じキーの結果は 1 回の実行で 1 回だけ取る（$1: キー, 残り: 実行するコマンド）
cached() {
  local file
  file="$work/cache/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
  shift
  if [ ! -s "$file" ]; then
    "$@" >"$file.tmp" || { rm -f "$file.tmp"; return 1; }
    mv "$file.tmp" "$file"
  fi
  cat "$file"
}

usage() {
  local kinds
  kinds=$(for entry in $DETAIL_KINDS; do printf '%s ' "${entry%%:*}"; done)
  cat >&2 <<USAGE
usage:
  $TOOL snapshot $SNAPSHOT_USAGE
  $TOOL detail --with KIND[,KIND...] [--interval SEC] [--max N] < records.jsonl

  KIND: ${kinds:-（なし）}
USAGE
  exit 1
}

# その種類の詳細が、そのレコード種別に当てはまるか（$1: 種類, $2: レコード種別）
kind_applies() {
  local entry
  for entry in $DETAIL_KINDS; do
    if [ "${entry%%:*}" = "$1" ]; then
      case ",${entry#*:}," in *",$2,"*) return 0 ;; esac
      return 1
    fi
  done
  return 1
}

kind_known() {
  local entry
  for entry in $DETAIL_KINDS; do
    [ "${entry%%:*}" = "$1" ] && return 0
  done
  return 1
}

detail_main() {
  local kinds="" max=100 kind
  interval=0.2
  while [ $# -gt 0 ]; do
    case "$1" in
      --with) kinds=${2//,/ }; shift 2 ;;
      --interval) interval=$2; shift 2 ;;
      --max) max=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$kinds" ] || usage
  for kind in $kinds; do
    kind_known "$kind" || die "不明な詳細の種類: $kind"
  done

  # 件数が多すぎるときは、絞り込み忘れとみなして止める
  cat >"$work/input.jsonl"
  local count
  count=$(grep -c . "$work/input.jsonl" || true)
  [ "$count" -le "$max" ] || die "入力が $count 件あり、上限（--max $max）を超えています。jq で絞り込むか、--max を上げてください"

  local record type details errors result
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    type=$(jq -r '.record_type' <<<"$record")
    details='{}'
    errors='[]'
    for kind in $kinds; do
      kind_applies "$kind" "$type" || continue
      if result=$("detail_$kind" "$record" 2>"$work/err"); then
        details=$(jq -c --arg k "$kind" --argjson v "$result" '.[$k] = $v' <<<"$details")
      else
        details=$(jq -c --arg k "$kind" '.[$k] = null' <<<"$details")
        errors=$(jq -c --argjson e "$(cli_error "$kind" "$work/err")" '. + [$e]' <<<"$errors")
      fi
    done
    jq -c --argjson d "$details" --argjson e "$errors" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + {details_collected_at: $at, details: $d, errors: ((.errors // []) + $e)}' <<<"$record"
  done <"$work/input.jsonl"
}

run_main() {
  case "${1:-}" in
    snapshot)
      shift
      local account
      account=$(aws sts get-caller-identity --query Account --output text </dev/null)
      common=$(jq -nc --arg a "$account" --arg r "$(current_region)" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{account_id: $a, region: $r, collected_at: $t}')
      snapshot_main "$@"
      ;;
    detail) shift; detail_main "$@" ;;
    *) usage ;;
  esac
}
