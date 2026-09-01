#!/usr/bin/env bash
# Step 5: 設定ファイルの switchover: approved と AWS の AVAILABLE 状態を確認して切り替える。
set -euo pipefail

usage() { echo 'Usage: switchover.sh --config FILE --service NAME --approve [--region REGION] [--profile PROFILE] [--output-dir DIR]'; }
config=''; service=''; approve=false; region=''; profile=''; output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --approve) approve=true; shift ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" && "$approve" == true ]] || { usage >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-switchover-step.XXXXXX")
mkdir -p "$output_dir"

# YAML の読み込みは 1 回だけ行い、以降は python3 -c を呼ばずシェル変数として使う。
eval "$(python3 -c '
import shlex, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = d["services"][sys.argv[2]]
a = s.get("actions", {})
values = {
    "approved": a.get("switchover", "pending"),
    "timeout": a.get("switchover_timeout", 300),
    "source_id": s["source_db_instance_identifier"],
    "config_region": d["aws_region"],
}
for k, v in values.items():
    print(f"{k}={shlex.quote(str(v))}")
' "$config" "$service")"
[[ "$approved" == approved ]] || { echo 'switchover: pending; no changes made.'; exit 0; }
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [読み取り] Source に紐づく Deployment を検索する。設定値ではなく AWS の実状態から対象 ID を解決する。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" --output json > "$output_dir/source.json"
source_arn=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --query 'DBInstances[0].DBInstanceArn' --output text)
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" --output json > "$output_dir/deployment.json"
deployment_id=$(aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
  --query 'BlueGreenDeployments[0].BlueGreenDeploymentIdentifier' --output text)
[[ -n "$deployment_id" && "$deployment_id" != None ]] || { echo "Blue/Green Deployment not found" >&2; exit 1; }

args=(--config "$config" --blue-green-deployment-id "$deployment_id" --approve --switchover-timeout "$timeout" --region "$region" --output-dir "$output_dir/result")
[[ -n "$profile" ]] && args+=(--profile "$profile")
"$(dirname "$0")/switchover_blue_green_deployment.sh" "${args[@]}"
echo "Switchover requested. Artifacts: $output_dir"
