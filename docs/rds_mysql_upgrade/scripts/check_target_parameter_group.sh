#!/usr/bin/env bash
# BuildGreen 前に、移行先 DB パラメータグループの存在とファミリーだけを確認する。
# AWS API は describe-db-parameter-groups（読み取り）だけを使用する。
set -euo pipefail

usage() {
  echo 'Usage: check_target_parameter_group.sh --config FILE --service NAME [--region REGION] [--profile PROFILE] [--output-dir DIR]'
}

config=''
service=''
region=''
profile=''
output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" ]] || { usage >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-target-pg-check.XXXXXX")
mkdir -p "$output_dir"

# config/blue-green/<environment>.yml から、確認対象のリモート DB
# パラメータグループ名・リージョン・目標エンジンバージョンを取得する。AWS API は呼ばない。
eval "$(python3 - "$config" "$service" <<'PY'
import shlex
import sys
import yaml

config_path, service_name = sys.argv[1:]
with open(config_path, encoding="utf-8") as handle:
    config = yaml.safe_load(handle)
try:
    service = config["services"][service_name]
    values = {
        "config_region": config["aws_region"],
        "target_parameter_group_name": service["target_db_parameter_group_name"],
        "target_engine_version": service["target_engine_version"],
    }
except KeyError as error:
    raise SystemExit(f"configuration key is missing: {error}")
for key, value in values.items():
    if not value:
        raise SystemExit(f"configuration value is empty: {key}")
    print(f"{key}={shlex.quote(str(value))}")
PY
)"
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region")
[[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [読み取り / レビュー注記]
# 指定した target_db_parameter_group_name が AWS に存在するか、どの
# DBParameterGroupFamily（例: mysql8.4）に属するかを取得する。
# create / modify / delete API は一切呼び出さない。
aws "${aws_args[@]}" rds describe-db-parameter-groups \
  --db-parameter-group-name "$target_parameter_group_name" \
  --output json > "$output_dir/target-db-parameter-group.json"

# Green の目標エンジンバージョンと、RDS が返したパラメーターグループの
# メジャー・マイナーファミリーが一致することを確認する。
python3 - \
  "$output_dir/target-db-parameter-group.json" \
  "$target_parameter_group_name" \
  "$target_engine_version" \
  > "$output_dir/target-parameter-group-check.md" <<'PY'
import json
import sys

result_path, expected_name, target_version = sys.argv[1:]
with open(result_path, encoding="utf-8") as handle:
    groups = json.load(handle).get("DBParameterGroups", [])
if len(groups) != 1:
    raise SystemExit(
        f"expected exactly one DB parameter group for {expected_name}, got {len(groups)}"
    )

group = groups[0]
actual_name = group.get("DBParameterGroupName", "")
actual_family = group.get("DBParameterGroupFamily", "")
expected_family = f"mysql{'.'.join(target_version.split('.')[:2])}"
matched = actual_name == expected_name and actual_family == expected_family

print("# 移行先 DB パラメータグループ事前確認")
print()
print(f"- 対象名: `{expected_name}`")
print(f"- RDS が返した名前: `{actual_name}`")
print(f"- 期待ファミリー: `{expected_family}`")
print(f"- RDS が返したファミリー: `{actual_family}`")
print(f"- 判定: {'PASS' if matched else 'FAIL'}")

if not matched:
    raise SystemExit(
        "target DB parameter group does not match the configured name or engine family"
    )
PY

echo "Target DB parameter group check passed. Artifacts: $output_dir"
