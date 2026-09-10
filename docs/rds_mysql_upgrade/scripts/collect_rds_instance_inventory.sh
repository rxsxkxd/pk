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
tmp_response=$(mktemp "${output}.response.XXXXXX")
trap 'rm -f "$tmp_output" "$tmp_response"' EXIT

# [読み取り / レビュー注記]
# DBInstanceIdentifier、Engine、EngineVersion、関連付く DBParameterGroups を含む
# DB インスタンス一覧を取得する。生成スクリプトはこの結果から移行元の
# エンジン major.minor とパラメータグループ名を補完する。
aws "${aws_args[@]}" rds describe-db-instances --output json > "$tmp_response"

# 読み取り結果を変更せず、収集に指定したリージョンだけをメタデータとして付与する。
# カタログに aws_region を重複記載せず、生成先設定の aws_region を決定するために使う。
python3 - "$tmp_response" "$tmp_output" "$region" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    response = json.load(handle)
if not isinstance(response, dict) or not isinstance(response.get("DBInstances"), list):
    raise SystemExit("describe-db-instances response has no DBInstances array")
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(
        {"aws_region": sys.argv[3], "DBInstances": response["DBInstances"]},
        handle,
        ensure_ascii=False,
        indent=2,
    )
    handle.write("\n")
PY

mv "$tmp_output" "$output"
trap - EXIT
echo "Collected RDS instance inventory: $output"
