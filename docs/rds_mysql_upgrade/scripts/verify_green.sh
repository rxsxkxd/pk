#!/usr/bin/env bash
# Step 4: Green の RDS 構成と ReplicaLag を AWS 読み取り API だけで検証する。
set -euo pipefail

# shellcheck source=lib/deployment_config.sh
source "$(dirname "$0")/lib/deployment_config.sh"

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

# shellcheck source=lib/migration_phase.sh
source "$(dirname "$0")/lib/migration_phase.sh"
# shellcheck source=lib/mysql_credentials.sh
source "$(dirname "$0")/lib/mysql_credentials.sh"

# 設定の読み込みは 1 回だけ行い、以降はシェル変数として使う。
# 必要な項目とその必須・任意だけをここに宣言する（取り出しは lib/config.jq）。
eval "$(deployment_config_vars "$config" "$service" '
  service($service) as $svc | {
    source_id:                            required("source_db_instance_identifier"; $svc.source_db_instance_identifier),
    source_engine_version:                required("source_engine_version"; $svc.source_engine_version),
    source_db_parameter_group_name:       required("source_db_parameter_group_name"; $svc.source_db_parameter_group_name),
    target_engine_version:                required("target_engine_version"; $svc.target_engine_version),
    target_db_instance_class:             required("target_db_instance_class"; $svc.target_db_instance_class),
    target_db_parameter_group_name:       required("target_db_parameter_group_name"; $svc.target_db_parameter_group_name),
    target_parameter_group_template_path: required("target_parameter_group_template_path"; $svc.target_parameter_group_template_path),
    config_region:                        required("aws_region"; .aws_region),
  } | shellvars')"
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [読み取り] 移行元識別子が指す実体を見て、検証すべきフェーズかを判定する。
# 切替後は <source_id> が green（新 Blue）を指すため、検証対象の Deployment は
# 既に SWITCHOVER_COMPLETED であり AVAILABLE ではない。そのままだと後始末フェーズで
# 再実行したときに必ず失敗するため、ここで「検証対象なし」として正常終了する。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" --output json > "$output_dir/source.json"
read -r current_version current_group <<< "$(
  aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
    --query 'DBInstances[0].[EngineVersion,DBParameterGroups[0].DBParameterGroupName]' --output text
)"
phase=$(resolve_migration_phase "$current_version" "$current_group" \
  "$source_engine_version" "$source_db_parameter_group_name" \
  "$target_engine_version" "$target_db_parameter_group_name")

if [[ "$phase" == post_switchover ]]; then
  echo "Already switched over: $source_id is ${current_version} with ${current_group}."
  echo 'Green の検証は切替前に行うものであり、検証対象はない。'
  echo "Artifacts: $output_dir"
  exit 0
fi

# [読み取り] Source ARN と、その Source に対応する Blue/Green Deployment を取得する。
source_arn=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --query 'DBInstances[0].DBInstanceArn' --output text)
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" --output json > "$output_dir/deployment.json"
read -r deployment_id target_arn status <<< "$(
  aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
    --query 'BlueGreenDeployments[0].[BlueGreenDeploymentIdentifier,Target,Status]' --output text
)"
if [[ -z "$deployment_id" || "$deployment_id" == None ]]; then
  echo "Blue/Green Deployment not found for $source_id" >&2
  echo "Step 3（build_green.sh）が未実行か、config の actions.build が pending の可能性がある。" >&2
  exit 1
fi
[[ "$status" == AVAILABLE ]] || { echo "Deployment is not AVAILABLE: $status" >&2; exit 1; }

# [読み取り] Green DB のエンジン、クラス、パラメータグループ関連付け・適用状態を取得して宣言値と突合する。
target_id=${target_arn##*:db:}
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$target_id" --output json > "$output_dir/green-db-instance.json"
read -r green_engine_version green_instance_class <<< "$(
  aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$target_id" \
    --query 'DBInstances[0].[EngineVersion,DBInstanceClass]' --output text
)"
green_pg_apply_status=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$target_id" \
  --query "DBInstances[0].DBParameterGroups[?DBParameterGroupName=='${target_db_parameter_group_name}'] | [0].ParameterApplyStatus" --output text)
[[ "$green_engine_version" == "$target_engine_version"* ]] || { echo "Green engine mismatch: $green_engine_version" >&2; exit 1; }
[[ "$green_instance_class" == "$target_db_instance_class" ]] || { echo "Green class mismatch: $green_instance_class" >&2; exit 1; }
[[ "$green_pg_apply_status" != None ]] || { echo "Green parameter group mismatch" >&2; exit 1; }
[[ "$green_pg_apply_status" == in-sync ]] || { echo "Green parameter group is not in-sync: $green_pg_apply_status" >&2; exit 1; }

# [DB 読み取り・任意] GitHub Environment Secret 等で接続情報が提供された場合、Green の
# MySQL 実効値を収集する。実効値はレポートにのみ掲載し、YAML との比較判定には使わない。
# [DB 読み取り・任意] Green の実効値を収集する。
# 接続方式は設定ファイルの mysql_verification が決める（parameter_store / plaintext /
# prompt）。--mysql-user を明示した場合は従来どおり呼び出し側の環境変数を使う。
read_mysql_verification_config "$config" "$service"
if [[ -n "$mysql_user" ]]; then
  # 後方互換: 呼び出し側が利用者とパスワード環境変数を直接指定した場合。
  MYSQL_VERIFY_USER="$mysql_user"
  MYSQL_VERIFY_PASSWORD="${!mysql_password_env:-}"
  MYSQL_VERIFY_ENABLED=true
elif [[ "$MYSQL_VERIFY_ENABLED" == true ]]; then
  resolve_mysql_credentials "$region" "$profile"
fi

if [[ "$MYSQL_VERIFY_ENABLED" == true && -z "$runtime_values_file" ]]; then
  green_endpoint=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$target_id" \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  collect_args=(
    --template "$target_parameter_group_template_path"
    --host "$green_endpoint"
    --user "$MYSQL_VERIFY_USER"
    --password-env MYSQL_VERIFY_PASSWORD
    --output "$output_dir/green-runtime-values.json"
  )
  # CA バンドルを指定した場合だけ TLS を検証する。パスワードを平文で流さないため推奨する。
  [[ -n "$MYSQL_VERIFY_SSL_CA" ]] && collect_args+=(--ssl-ca "$MYSQL_VERIFY_SSL_CA")
  export MYSQL_VERIFY_PASSWORD
  "$(dirname "$0")/collect_green_runtime_values.sh" "${collect_args[@]}"
  unset MYSQL_VERIFY_PASSWORD
  runtime_values_file="$output_dir/green-runtime-values.json"
fi

# [読み取り] Green に反映された Source=user / Source=system / 全パラメータを取得する。
# 後段のレポートで、Step 2 の CloudFormation YAML と Source=user を突き合わせる。
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$target_db_parameter_group_name" --source user --output json > "$output_dir/green-user-parameters.json"
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$target_db_parameter_group_name" --source system --output json > "$output_dir/green-system-parameters.json"
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$target_db_parameter_group_name" --output json > "$output_dir/green-all-parameters.json"
# GNU date 前提（-d オプション）。本リポジトリの実行はいずれも GNU coreutils を含むコンテナ経由を想定する。
end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
aws "${aws_args[@]}" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag --dimensions "Name=DBInstanceIdentifier,Value=$target_id" --statistics Maximum --period 60 --start-time "$start_time" --end-time "$end_time" --output json > "$output_dir/replica-lag.json"
replica_lag_failed=false
# JMESPath の max() は空配列に null を返す（--output text では "None"）。
replica_lag_max=$(aws "${aws_args[@]}" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag --dimensions "Name=DBInstanceIdentifier,Value=$target_id" --statistics Maximum --period 60 --start-time "$start_time" --end-time "$end_time" --query 'max(Datapoints[].Maximum)' --output text)
if [[ "$replica_lag_max" == None ]]; then
  echo "ReplicaLag datapoint is unavailable" >&2
  replica_lag_failed=true
elif ! awk -v v="$replica_lag_max" 'BEGIN{exit !(v<=0)}'; then
  echo "ReplicaLag is not zero: $replica_lag_max" >&2
  replica_lag_failed=true
fi
report_args=(
  --template "$target_parameter_group_template_path" \
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
