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

# CloudFormation YAML で明示したパラメーター名だけを SQL に展開する。値は SQL に含めない。
sql=$(python3 -c 'import re,sys,yaml; t=yaml.safe_load(open(sys.argv[1])); r=next((v for v in t["Resources"].values() if v.get("Type") == "AWS::RDS::DBParameterGroup"), None); r or (_ for _ in ()).throw(SystemExit("AWS::RDS::DBParameterGroup not found")); n=list(r.get("Properties", {}).get("Parameters", {}).keys()); n or (_ for _ in ()).throw(SystemExit("No declared parameters")); all(re.fullmatch(r"[A-Za-z0-9_]+", x) for x in n) or (_ for _ in ()).throw(SystemExit("Invalid parameter name")); print("SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME IN (" + ",".join(repr(x) for x in n) + ") ORDER BY VARIABLE_NAME;")' "$template")

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
python3 -c 'import datetime,json,sys; v={}; [v.__setitem__(p[0], p[1] if len(p)>1 else "") for p in (line.rstrip("\n").split("\t", 1) for line in open(sys.argv[1])) if p[0]]; json.dump({"CollectedAt":datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"), "Parameters":v}, open(sys.argv[2], "w"), ensure_ascii=False, indent=2); open(sys.argv[2], "a").write("\n")' "$tmp_output" "$output"
echo "Collected runtime values: $output"
