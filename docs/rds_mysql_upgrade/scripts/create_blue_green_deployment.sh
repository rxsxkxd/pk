#!/usr/bin/env bash
# Step 3 内部処理: build_green.sh から呼ばれる。CloudFormation で事前作成済みの
# MySQL 8.4 DB パラメータグループを直接指定し、RDS for MySQL 8.0 の Blue から 8.4 の Green を作成する。
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
# YAML の読み込みは 1 回だけ行い、以降は python3 -c を呼ばずシェル変数として使う。
eval "$(python3 -c '
import shlex, sys, yaml
c, s = sys.argv[1:]
d = yaml.safe_load(open(c))
t = d["services"][s]
for k in ("source_db_instance_identifier", "target_engine_version", "target_db_instance_class", "target_db_parameter_group_name"):
    if not t.get(k):
        sys.exit(f"{c}: services.{s}.{k} が未定義です")
for k in ("environment", "aws_region"):
    if not d.get(k):
        sys.exit(f"{c}: {k} が未定義です")
values = {
    "source_db_instance_identifier": t["source_db_instance_identifier"],
    "target_engine_version": t["target_engine_version"],
    "target_db_instance_class": t["target_db_instance_class"],
    "target_db_parameter_group_name": t["target_db_parameter_group_name"],
    "environment": d["environment"],
    "config_region": d["aws_region"],
    "config_profile": d.get("aws_profile", ""),
}
for k, v in values.items():
    print(f"{k}={shlex.quote(str(v))}")
' "$config" "$service")"
[[ -n "$region" ]] || region=$config_region
[[ -n "$profile" ]] || profile=$config_profile
aws_args=(--region "$region")
[[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [作成前・読み取り] 移行元 Blue DB の ARN・エンジン・現在の状態を取得する。
# CreateBlueGreenDeployment の Source に渡す ARN を確定し、8.0 MySQL であることを確認するための操作。
aws "${aws_args[@]}" rds describe-db-instances \
  --db-instance-identifier "$source_db_instance_identifier" \
  --output json > "$output_dir/source-db-instance.json"
read -r source_db_instance_engine source_db_instance_engine_version source_db_instance_arn <<< "$(
  aws "${aws_args[@]}" rds describe-db-instances \
    --db-instance-identifier "$source_db_instance_identifier" \
    --query 'DBInstances[0].[Engine,EngineVersion,DBInstanceArn]' --output text
)"
[[ "$source_db_instance_engine" == mysql ]] || { echo "Source DB engine must be mysql: $source_db_instance_engine" >&2; exit 1; }
[[ "$source_db_instance_engine_version" == 8.0.* ]] || { echo "Source DB engine must be MySQL 8.0: $source_db_instance_engine_version" >&2; exit 1; }

# [作成前・読み取り] CloudFormation で事前作成した DB パラメータグループの family を取得する。
# Green の MySQL 8.4 に適用可能な mysql8.4 ファミリーであることを確認するための操作。
aws "${aws_args[@]}" rds describe-db-parameter-groups \
  --db-parameter-group-name "$target_db_parameter_group_name" \
  --output json > "$output_dir/target-db-parameter-group.json"
target_db_parameter_group_family=$(aws "${aws_args[@]}" rds describe-db-parameter-groups \
  --db-parameter-group-name "$target_db_parameter_group_name" \
  --query 'DBParameterGroups[0].DBParameterGroupFamily' --output text)
[[ "$target_db_parameter_group_family" == mysql8.4 ]] || { echo "Target DB parameter group family must be mysql8.4: $target_db_parameter_group_family" >&2; exit 1; }

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
# create-blue-green-deployment は変更操作であり呼び直せない（呼び直すと二重作成になる）。
# --query による再取得ができないため、保存済みレスポンス JSON から読み取る。
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
  status=$(aws "${aws_args[@]}" rds describe-blue-green-deployments \
    --blue-green-deployment-identifier "$deployment_identifier" \
    --query 'BlueGreenDeployments[0].Status' --output text)
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
