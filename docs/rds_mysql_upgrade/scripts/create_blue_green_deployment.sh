#!/usr/bin/env bash
# CloudFormation で事前作成済みの MySQL 8.4 DB パラメータグループを直接指定し、
# RDS for MySQL 8.0 の Blue から 8.4 の Green を作成する。
# Green が AVAILABLE になるまで待機して終了する。切替は実施しない。
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: create_blue_green_deployment.sh --config FILE --service NAME [options]
  --config FILE               環境別設定ファイル（必須）
  --service NAME              config の services 配下に定義したサービス名（必須）
  --deployment-name NAME      Blue/Green Deployment 名（省略時はサービス・環境・時刻から生成）
  --region REGION             AWS Region（設定ファイルの aws_region を上書き）
  --profile PROFILE           AWS CLI profile（省略時は AWS CLI の既定認証情報）
  --output-dir DIR            応答 JSON の保存先（default: temporary directory）
  --wait-timeout-seconds SEC  AVAILABLE 待機の上限秒数（default: 3600）
USAGE
}

service=''; deployment_name=''; config=''
region=''; profile=''; output_dir=''; wait_timeout_seconds=3600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) service=${2:?}; shift 2 ;;
    --deployment-name) deployment_name=${2:?}; shift 2 ;;
    --config) config=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    --wait-timeout-seconds) wait_timeout_seconds=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$service" ]] || { echo '--service is required.' >&2; exit 2; }
[[ -n "$config" ]] || { echo '--config is required.' >&2; exit 2; }
[[ "$wait_timeout_seconds" =~ ^[0-9]+$ ]] || { echo '--wait-timeout-seconds must be an integer.' >&2; exit 2; }

[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-create.XXXXXX")
mkdir -p "$output_dir"
# config のサービスに対応する作成設定を読み取る。AWS API は呼び出さない。
python3 -c 'import json,sys,yaml; c,s=sys.argv[1:]; d=yaml.safe_load(open(c)); t=d["services"][s]; [(_ for _ in ()).throw(SystemExit(f"{c}: services.{s}.{k} が未定義です")) for k in ("source_db_instance_identifier", "target_engine_version", "target_db_instance_class", "target_db_parameter_group_name") if not t.get(k)]; [(_ for _ in ()).throw(SystemExit(f"{c}: {k} が未定義です")) for k in ("environment", "aws_region") if not d.get(k)]; print(json.dumps({**t, "environment":d["environment"], "aws_region":d["aws_region"], "aws_profile":d.get("aws_profile", "")}))' "$config" "$service" > "$output_dir/target.json"

read_target() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$output_dir/target.json" "$1"
}
source_db_instance_identifier=$(read_target source_db_instance_identifier)
target_engine_version=$(read_target target_engine_version)
target_db_instance_class=$(read_target target_db_instance_class)
target_db_parameter_group_name=$(read_target target_db_parameter_group_name)
environment=$(read_target environment)
[[ -n "$region" ]] || region=$(read_target aws_region)
[[ -n "$profile" ]] || profile=$(read_target aws_profile)
aws_args=(--region "$region")
[[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [作成前・読み取り] 移行元 Blue DB の ARN・エンジン・現在の状態を取得する。
# CreateBlueGreenDeployment の Source に渡す ARN を確定し、8.0 MySQL であることを確認するための操作。
aws "${aws_args[@]}" rds describe-db-instances \
  --db-instance-identifier "$source_db_instance_identifier" \
  --output json > "$output_dir/source-db-instance.json"
source_db_instance_arn=$(python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))["DBInstances"][0]; i["Engine"] == "mysql" or (_ for _ in ()).throw(SystemExit(f"Source DB engine must be mysql: {i[\"Engine\"]}")); i["EngineVersion"].startswith("8.0.") or (_ for _ in ()).throw(SystemExit(f"Source DB engine must be MySQL 8.0: {i[\"EngineVersion\"]}")); print(i["DBInstanceArn"])' "$output_dir/source-db-instance.json")

# [作成前・読み取り] CloudFormation で事前作成した DB パラメータグループの family を取得する。
# Green の MySQL 8.4 に適用可能な mysql8.4 ファミリーであることを確認するための操作。
aws "${aws_args[@]}" rds describe-db-parameter-groups \
  --db-parameter-group-name "$target_db_parameter_group_name" \
  --output json > "$output_dir/target-db-parameter-group.json"
python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["DBParameterGroups"][0]; g["DBParameterGroupFamily"] == "mysql8.4" or (_ for _ in ()).throw(SystemExit(f"Target DB parameter group family must be mysql8.4: {g[\"DBParameterGroupFamily\"]}"))' "$output_dir/target-db-parameter-group.json"

[[ -n "$deployment_name" ]] || deployment_name="${service}-${environment}-mysql84-bg-$(date -u +%Y%m%d%H%M%S)"
[[ "$deployment_name" =~ ^[A-Za-z][A-Za-z0-9-]{0,59}$ ]] || { echo "Invalid --deployment-name: $deployment_name" >&2; exit 2; }

# [変更] 8.0 の Source から MySQL 8.4 Green を作成する。
# target_db_parameter_group_name は CloudFormation が作成済みの実名を RDS API に直接渡す。
aws "${aws_args[@]}" rds create-blue-green-deployment \
  --blue-green-deployment-name "$deployment_name" \
  --source "$source_db_instance_arn" \
  --target-engine-version "$target_engine_version" \
  --target-db-instance-class "$target_db_instance_class" \
  --target-db-parameter-group-name "$target_db_parameter_group_name" \
  --output json > "$output_dir/create-blue-green-deployment.json"
deployment_identifier=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["BlueGreenDeployment"]["BlueGreenDeploymentIdentifier"])' "$output_dir/create-blue-green-deployment.json")

echo "Created Blue/Green Deployment: $deployment_identifier"
echo "Waiting for status AVAILABLE before verification..."
deadline=$(( $(date +%s) + wait_timeout_seconds ))
while true; do
  # [待機中・読み取り] Green の構築状態と、作成された Green DB の ARN を取得する。
  # AVAILABLE になった時点で終了し、アプリケーション・接続・性能検証へ進む。
  aws "${aws_args[@]}" rds describe-blue-green-deployments \
    --blue-green-deployment-identifier "$deployment_identifier" \
    --output json > "$output_dir/describe-blue-green-deployment.json"
  status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["BlueGreenDeployments"][0]["Status"])' "$output_dir/describe-blue-green-deployment.json")
  echo "Blue/Green status: $status"
  [[ "$status" == 'AVAILABLE' ]] && break
  case "$status" in
    INVALID_CONFIGURATION|FAILED|DELETED) echo "Blue/Green creation failed: $status" >&2; exit 1 ;;
  esac
  [[ $(date +%s) -lt $deadline ]] || { echo "Timed out waiting for AVAILABLE." >&2; exit 1; }
  sleep 30
done

echo "Green is AVAILABLE. Perform verification before switchover."
echo "Deployment identifier: $deployment_identifier"
echo "Artifacts: $output_dir"
echo "Switchover: scripts/switchover_blue_green_deployment.sh --blue-green-deployment-id $deployment_identifier --approve"
