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

python3 -c 'import json,sys,yaml; d=yaml.safe_load(open(sys.argv[1])); s=d["services"][sys.argv[2]]; a=s.get("actions", {}); print(json.dumps({"approved":a.get("switchover", "pending"), "timeout":a.get("switchover_timeout", 300), "source":s["source_db_instance_identifier"], "region":d["aws_region"]}))' "$config" "$service" > "$output_dir/config.json"
read_config() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$output_dir/config.json" "$1"; }
[[ "$(read_config approved)" == approved ]] || { echo 'switchover: pending; no changes made.'; exit 0; }
[[ -n "$region" ]] || region=$(read_config region)
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [読み取り] Source に紐づく Deployment を検索する。設定値ではなく AWS の実状態から対象 ID を解決する。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$(read_config source)" --output json > "$output_dir/source.json"
source_arn=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["DBInstances"][0]["DBInstanceArn"])' "$output_dir/source.json")
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" --output json > "$output_dir/deployment.json"
deployment_id=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["BlueGreenDeployments"]; d or (_ for _ in ()).throw(SystemExit("Blue/Green Deployment not found")); print(d[0]["BlueGreenDeploymentIdentifier"])' "$output_dir/deployment.json")

args=(--config "$config" --blue-green-deployment-id "$deployment_id" --approve --switchover-timeout "$(read_config timeout)" --region "$region" --output-dir "$output_dir/result")
[[ -n "$profile" ]] && args+=(--profile "$profile")
"$(dirname "$0")/switchover_blue_green_deployment.sh" "${args[@]}"
echo "Switchover requested. Artifacts: $output_dir"
