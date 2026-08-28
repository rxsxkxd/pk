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

python3 -c 'import json,sys,yaml; d=yaml.safe_load(open(sys.argv[1])); t=d["services"][sys.argv[2]]; [(_ for _ in ()).throw(SystemExit(f"missing {k}")) for k in ("source_db_instance_identifier", "target_engine_version", "target_db_instance_class", "target_db_parameter_group_name", "target_parameter_group_template_path") if not t.get(k)]; print(json.dumps({**t, "region":d["aws_region"]}))' "$config" "$service" > "$output_dir/config.json"
read_config() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$output_dir/config.json" "$1"; }
[[ -n "$region" ]] || region=$(read_config region)
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")
source_id=$(read_config source_db_instance_identifier)

# [読み取り] Source ARN と、その Source に対応する Blue/Green Deployment を取得する。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" --output json > "$output_dir/source.json"
source_arn=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["DBInstances"][0]["DBInstanceArn"])' "$output_dir/source.json")
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" --output json > "$output_dir/deployment.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))["BlueGreenDeployments"] or (_ for _ in ()).throw(SystemExit("Blue/Green Deployment not found"))' "$output_dir/deployment.json"
deployment_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["BlueGreenDeployments"][0]["BlueGreenDeploymentIdentifier"])' "$output_dir/deployment.json")
target_arn=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["BlueGreenDeployments"][0]["Target"])' "$output_dir/deployment.json")
status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["BlueGreenDeployments"][0]["Status"])' "$output_dir/deployment.json")
[[ "$status" == AVAILABLE ]] || { echo "Deployment is not AVAILABLE: $status" >&2; exit 1; }

# [読み取り] Green DB のエンジン、クラス、パラメータグループ関連付け・適用状態を取得して宣言値と突合する。
target_id=${target_arn##*:db:}
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$target_id" --output json > "$output_dir/green-db-instance.json"
python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); i=json.load(open(sys.argv[2]))["DBInstances"][0]; i["EngineVersion"].startswith(e["target_engine_version"]) or (_ for _ in ()).throw(SystemExit(f"Green engine mismatch: {i[\"EngineVersion\"]}")); i["DBInstanceClass"] == e["target_db_instance_class"] or (_ for _ in ()).throw(SystemExit(f"Green class mismatch: {i[\"DBInstanceClass\"]}")); g=next((x for x in i["DBParameterGroups"] if x["DBParameterGroupName"] == e["target_db_parameter_group_name"]), None); g or (_ for _ in ()).throw(SystemExit("Green parameter group mismatch")); g["ParameterApplyStatus"] == "in-sync" or (_ for _ in ()).throw(SystemExit(f"Green parameter group is not in-sync: {g[\"ParameterApplyStatus\"]}"))' "$output_dir/config.json" "$output_dir/green-db-instance.json"

# [DB 読み取り・任意] GitHub Environment Secret 等で接続情報が提供された場合、Green の
# MySQL 実効値を収集する。実効値はレポートにのみ掲載し、YAML との比較判定には使わない。
if [[ -n "$mysql_user" && -z "$runtime_values_file" ]]; then
  green_endpoint=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["DBInstances"][0]["Endpoint"]["Address"])' "$output_dir/green-db-instance.json")
  "$(dirname "$0")/collect_green_runtime_values.sh" \
    --template "$(read_config target_parameter_group_template_path)" \
    --host "$green_endpoint" \
    --user "$mysql_user" \
    --password-env "$mysql_password_env" \
    --output "$output_dir/green-runtime-values.json"
  runtime_values_file="$output_dir/green-runtime-values.json"
fi

# [読み取り] Green に反映された Source=user / Source=system / 全パラメータを取得する。
# 後段のレポートで、Step 2 の CloudFormation YAML と Source=user を突き合わせる。
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$(read_config target_db_parameter_group_name)" --source user --output json > "$output_dir/green-user-parameters.json"
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$(read_config target_db_parameter_group_name)" --source system --output json > "$output_dir/green-system-parameters.json"
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$(read_config target_db_parameter_group_name)" --output json > "$output_dir/green-all-parameters.json"
end_time=$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))')
start_time=$(python3 -c 'from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)-timedelta(minutes=10)).isoformat().replace("+00:00", "Z"))')
aws "${aws_args[@]}" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag --dimensions "Name=DBInstanceIdentifier,Value=$target_id" --statistics Maximum --period 60 --start-time "$start_time" --end-time "$end_time" --output json > "$output_dir/replica-lag.json"
replica_lag_failed=false
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["Datapoints"]; p or (_ for _ in ()).throw(SystemExit("ReplicaLag datapoint is unavailable")); m=max(x["Maximum"] for x in p); m <= 0 or (_ for _ in ()).throw(SystemExit(f"ReplicaLag is not zero: {m}"))' "$output_dir/replica-lag.json" || replica_lag_failed=true
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
# CI は GREEN_REPORT_GENERATOR にマルチステージ Docker ビルド済み Go バイナリを指定する。
# 指定がないローカル実行では、互換性のため既存 Ruby 版を使用する。
report_generator=${GREEN_REPORT_GENERATOR:-"$(dirname "$0")/generate_green_verification_report.rb"}
"$report_generator" "${report_args[@]}"
if [[ "$replica_lag_failed" == true ]]; then
  echo "Artifacts: $output_dir"
  echo 'VERIFY FAILED: ReplicaLag is not zero or unavailable.' >&2
  exit 1
fi
echo "VERIFY PASSED: $deployment_id"
echo "Artifacts: $output_dir"
