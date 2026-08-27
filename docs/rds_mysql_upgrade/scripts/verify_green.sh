#!/usr/bin/env bash
# Step 4: Green の RDS 構成と ReplicaLag を AWS 読み取り API だけで検証する。
set -euo pipefail

usage() { echo 'Usage: verify_green.sh --config FILE --service NAME [--runtime-values-file FILE | --mysql-user USER] [--mysql-password-env NAME] [--region REGION] [--profile PROFILE] [--output-dir DIR]'; }
config=''; service=''; runtime_values_file=''; mysql_user=''; mysql_password_env='MYSQL_PASSWORD'; region=''; profile=''; output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --runtime-values-file) runtime_values_file=${2:?}; shift 2 ;;
    --mysql-user) mysql_user=${2:?}; shift 2 ;;
    --mysql-password-env) mysql_password_env=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" ]] || { usage >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-verify.XXXXXX")
mkdir -p "$output_dir"

ruby -ryaml -rjson -e '
  document = YAML.load_file(ARGV[0]); target = document.fetch("services").fetch(ARGV[1])
  %w[source_db_instance_identifier target_engine_version target_db_instance_class target_db_parameter_group_name target_parameter_group_template_path].each { |key| abort("missing #{key}") if target[key].to_s.empty? }
  puts JSON.generate(target.merge("region" => document.fetch("aws_region")))
' "$config" "$service" > "$output_dir/config.json"
read_config() { ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch(ARGV[1])' "$output_dir/config.json" "$1"; }
[[ -n "$region" ]] || region=$(read_config region)
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")
source_id=$(read_config source_db_instance_identifier)

# [読み取り] Source ARN と、その Source に対応する Blue/Green Deployment を取得する。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" --output json > "$output_dir/source.json"
source_arn=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("DBInstances").fetch(0).fetch("DBInstanceArn")' "$output_dir/source.json")
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" --output json > "$output_dir/deployment.json"
ruby -rjson -e 'abort("Blue/Green Deployment not found") if JSON.parse(File.read(ARGV[0])).fetch("BlueGreenDeployments").empty?' "$output_dir/deployment.json"
deployment_id=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("BlueGreenDeployments").fetch(0).fetch("BlueGreenDeploymentIdentifier")' "$output_dir/deployment.json")
target_arn=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("BlueGreenDeployments").fetch(0).fetch("Target")' "$output_dir/deployment.json")
status=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("BlueGreenDeployments").fetch(0).fetch("Status")' "$output_dir/deployment.json")
[[ "$status" == AVAILABLE ]] || { echo "Deployment is not AVAILABLE: $status" >&2; exit 1; }

# [読み取り] Green DB のエンジン、クラス、パラメータグループ関連付け・適用状態を取得して宣言値と突合する。
target_id=${target_arn##*:db:}
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$target_id" --output json > "$output_dir/green-db-instance.json"
ruby -rjson -e '
  expected = JSON.parse(File.read(ARGV[0])); instance = JSON.parse(File.read(ARGV[1])).fetch("DBInstances").fetch(0)
  abort("Green engine mismatch: #{instance["EngineVersion"]}") unless instance.fetch("EngineVersion").start_with?(expected.fetch("target_engine_version"))
  abort("Green class mismatch: #{instance["DBInstanceClass"]}") unless instance["DBInstanceClass"] == expected.fetch("target_db_instance_class")
  group = instance.fetch("DBParameterGroups").find { |g| g["DBParameterGroupName"] == expected.fetch("target_db_parameter_group_name") }
  abort("Green parameter group mismatch") unless group
  abort("Green parameter group is not in-sync: #{group["ParameterApplyStatus"]}") unless group["ParameterApplyStatus"] == "in-sync"
' "$output_dir/config.json" "$output_dir/green-db-instance.json"

# [DB 読み取り・任意] GitHub Environment Secret 等で接続情報が提供された場合、Green の
# MySQL 実効値を収集する。実効値はレポートにのみ掲載し、YAML との比較判定には使わない。
if [[ -n "$mysql_user" && -z "$runtime_values_file" ]]; then
  green_endpoint=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("DBInstances").fetch(0).fetch("Endpoint").fetch("Address")' "$output_dir/green-db-instance.json")
  "$(dirname "$0")/collect_green_runtime_values.sh" \
    --template "$(read_config target_parameter_group_template_path)" \
    --host "$green_endpoint" \
    --user "$mysql_user" \
    --password-env "$mysql_password_env" \
    --output "$output_dir/green-runtime-values.json"
  runtime_values_file="$output_dir/green-runtime-values.json"
fi

# [読み取り] Green に反映された Source=user / Source=system / 全パラメータを取得する。
# 後段の Ruby レポートで、Step 2 の CloudFormation YAML と Source=user を突き合わせる。
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$(read_config target_db_parameter_group_name)" --source user --output json > "$output_dir/green-user-parameters.json"
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$(read_config target_db_parameter_group_name)" --source system --output json > "$output_dir/green-system-parameters.json"
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$(read_config target_db_parameter_group_name)" --output json > "$output_dir/green-all-parameters.json"
end_time=$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))')
start_time=$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)-timedelta(minutes=10)).isoformat().replace("+00:00", "Z"))')
aws "${aws_args[@]}" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag --dimensions "Name=DBInstanceIdentifier,Value=$target_id" --statistics Maximum --period 60 --start-time "$start_time" --end-time "$end_time" --output json > "$output_dir/replica-lag.json"
replica_lag_failed=false
ruby -rjson -e '
  points = JSON.parse(File.read(ARGV[0])).fetch("Datapoints"); abort("ReplicaLag datapoint is unavailable") if points.empty?
  max = points.map { |p| p.fetch("Maximum") }.max; abort("ReplicaLag is not zero: #{max}") unless max <= 0
' "$output_dir/replica-lag.json" || replica_lag_failed=true
report_args=(
  --template "$(read_config target_parameter_group_template_path)" \
  --green-instance "$output_dir/green-db-instance.json" \
  --deployment "$output_dir/deployment.json" \
  --user-parameters "$output_dir/green-user-parameters.json" \
  --system-parameters "$output_dir/green-system-parameters.json" \
  --all-parameters "$output_dir/green-all-parameters.json" \
  --replica-lag "$output_dir/replica-lag.json" \
  --output "$output_dir/green-verification-report.md"
)
[[ -n "$runtime_values_file" ]] && report_args+=(--runtime-values "$runtime_values_file")
"$(dirname "$0")/generate_green_verification_report.rb" "${report_args[@]}"
if [[ "$replica_lag_failed" == true ]]; then
  echo "Artifacts: $output_dir"
  echo 'VERIFY FAILED: ReplicaLag is not zero or unavailable.' >&2
  exit 1
fi
echo "VERIFY PASSED: $deployment_id"
echo "Artifacts: $output_dir"
