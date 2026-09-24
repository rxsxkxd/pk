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
# JSON の読み取りに jq を使う（設定 YAML も Ruby で JSON 化してから jq で読む）。
command -v jq >/dev/null 2>&1 || { echo 'jq が見つからない。JSON の読み取りに必要である。' >&2; exit 1; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-target-pg-check.XXXXXX")
mkdir -p "$output_dir"

# config/blue-green/<environment>.deployment.yml から、確認対象のリモート DB
# パラメータグループ名・リージョン・目標エンジンバージョンを取得する。AWS API は呼ばない。
config_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
  config_region=required:aws_region \
  target_parameter_group_name=required:service.target_db_parameter_group_name \
  target_engine_version=required:service.target_engine_version)
eval "$config_vars"
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
result_json="$output_dir/target-db-parameter-group.json"

# 名前を指定して引いているため応答は 1 件のはずである。0 件・複数件は前提が
# 崩れているので、判定せずに落とす。
group_count=$(jq '.DBParameterGroups | length' "$result_json")
if [[ "$group_count" != 1 ]]; then
  echo "expected exactly one DB parameter group for ${target_parameter_group_name}, got ${group_count}" >&2
  exit 1
fi

actual_name=$(jq -r '.DBParameterGroups[0].DBParameterGroupName // ""' "$result_json")
actual_family=$(jq -r '.DBParameterGroups[0].DBParameterGroupFamily // ""' "$result_json")

# 8.4.10 → mysql8.4。パッチバージョンはファミリー名に含まれない。
if [[ "$target_engine_version" == *.* ]]; then
  version_major=${target_engine_version%%.*}
  version_rest=${target_engine_version#*.}
  expected_family="mysql${version_major}.${version_rest%%.*}"
else
  expected_family="mysql${target_engine_version}"
fi

verdict=PASS
if [[ "$actual_name" != "$target_parameter_group_name" || "$actual_family" != "$expected_family" ]]; then
  verdict=FAIL
fi

# 判定結果は不適合でも成果物に残す。CI のログだけでなくレポートからも追えるようにする。
{
  printf '# 移行先 DB パラメータグループ事前確認\n'
  printf '\n'
  printf -- '- 対象名: `%s`\n' "$target_parameter_group_name"
  printf -- '- RDS が返した名前: `%s`\n' "$actual_name"
  printf -- '- 期待ファミリー: `%s`\n' "$expected_family"
  printf -- '- RDS が返したファミリー: `%s`\n' "$actual_family"
  printf -- '- 判定: %s\n' "$verdict"
} > "$output_dir/target-parameter-group-check.md"

if [[ "$verdict" != PASS ]]; then
  echo 'target DB parameter group does not match the configured name or engine family' >&2
  exit 1
fi

echo "Target DB parameter group check passed. Artifacts: $output_dir"
