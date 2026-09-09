#!/usr/bin/env bash
# Blue/Green 設定生成用に、RDS DB インスタンスの事実情報を収集する。
# AWS API は rds describe-db-instances（読み取り）だけを使用し、変更操作は行わない。
set -euo pipefail

usage() {
  echo 'Usage: collect_rds_instance_inventory.sh --region REGION --output FILE [--profile PROFILE]'
}

region=''
profile=''
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output) output=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$region" && -n "$output" ]] || { usage >&2; exit 2; }
mkdir -p "$(dirname "$output")"

aws_args=(--region "$region")
[[ -n "$profile" ]] && aws_args+=(--profile "$profile")

tmp_output=$(mktemp "${output}.XXXXXX")
trap 'rm -f "$tmp_output"' EXIT

# [読み取り / レビュー注記]
# DBInstanceIdentifier、Engine、EngineVersion、関連付く DBParameterGroups を含む
# DB インスタンス一覧を取得する。生成スクリプトはこの結果から移行元の
# エンジン major.minor とパラメータグループ名を補完する。
aws "${aws_args[@]}" rds describe-db-instances --output json > "$tmp_output"

mv "$tmp_output" "$output"
trap - EXIT
echo "Collected RDS instance inventory: $output"
