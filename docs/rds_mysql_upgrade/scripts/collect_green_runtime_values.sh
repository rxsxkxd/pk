#!/usr/bin/env bash
# Step 4 補助: MySQL クライアントで Green DB の実効値を収集する。AWS API は呼び出さない。
set -euo pipefail

usage() { echo 'Usage: collect_green_runtime_values.sh --template FILE --host HOST --user USER --output FILE [--password-env NAME] [--defaults-extra-file FILE] [--ssl-ca FILE]'; }
template=''; host=''; user=''; output=''; password_env='MYSQL_PASSWORD'; defaults_file=''; ssl_ca=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) template=${2:?}; shift 2 ;;
    --host) host=${2:?}; shift 2 ;;
    --user) user=${2:?}; shift 2 ;;
    --output) output=${2:?}; shift 2 ;;
    --password-env) password_env=${2:?}; shift 2 ;;
    --defaults-extra-file) defaults_file=${2:?}; shift 2 ;;
    --ssl-ca) ssl_ca=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$template" && -n "$host" && -n "$user" && -n "$output" ]] || { usage >&2; exit 2; }
# JSON の読み取りに jq を使う（設定 YAML も python3 で JSON 化してから jq で読む）。
command -v jq >/dev/null 2>&1 || { echo 'jq が見つからない。JSON の読み取りに必要である。' >&2; exit 1; }

# CloudFormation YAML で明示したパラメーター名だけを SQL に展開する。値は SQL に含めない。
# テンプレートの読み取り（短縮記法 !Ref / !Sub の正規化を含む）は Go の
# list_db_parameter_names に委ねる。この経路は Step 4 でしか通らないため、
# Go への依存は VerifyGreen に閉じている。
names=$(go -C "$(cd "$(dirname "$0")/.." && pwd)" run ./scripts/list_db_parameter_names \
  --template "$(cd "$(dirname "$template")" && pwd)/$(basename "$template")")
# 名前を SQL の IN リストへ組み立てる。名前は Go 側で [A-Za-z0-9_]+ に限定済みである。
sql=$(printf '%s\n' "$names" | jq -R -s -r '
  [splits("\n") | select(length > 0) | "\u0027\(.)\u0027"] | join(",")
  | "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables "
    + "WHERE VARIABLE_NAME IN (\(.)) ORDER BY VARIABLE_NAME;"')

tmp_output=$(mktemp "${TMPDIR:-/tmp}/rds-green-runtime.XXXXXX")
trap 'rm -f "$tmp_output"' EXIT
mysql_args=(--batch --skip-column-names --raw --host="$host" --user="$user")
[[ -n "$defaults_file" ]] && mysql_args+=(--defaults-extra-file="$defaults_file")
[[ -n "$ssl_ca" ]] && mysql_args+=(--ssl-mode=VERIFY_CA --ssl-ca="$ssl_ca")

# [DB 読み取り] performance_schema.global_variables から、Green DB が実際に採用している実効値を取得する。
if [[ -n "${!password_env:-}" ]]; then
  # CI の GitHub Environment Secret を MySQL クライアントの実行プロセスだけに渡す。
  # コマンド引数・成果物には出力しない。
  env "MYSQL_PWD=${!password_env}" mysql "${mysql_args[@]}" --execute="$sql" > "$tmp_output"
else
  # ローカル実行は MySQL クライアントの対話入力を使用する。
  mysql "${mysql_args[@]}" --password --execute="$sql" > "$tmp_output"
fi
# MySQL の --batch 出力（変数名 TAB 値）を JSON へ組み立てる。
# 値そのものにタブが含まれても壊れないよう、最初のタブだけで区切る。
jq -Rn --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  reduce (inputs | select(length > 0)) as $line ({};
    ($line | index("\t")) as $separator
    | if $separator == null then . + {($line): ""}
      else . + {($line[0:$separator]): $line[$separator + 1:]}
      end)
  | {CollectedAt: $collected_at, Parameters: .}
' < "$tmp_output" > "$output"
echo "Collected runtime values: $output"
