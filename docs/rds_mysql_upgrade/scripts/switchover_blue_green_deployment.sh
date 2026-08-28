#!/usr/bin/env bash
# 検証済みの RDS Blue/Green Deployment を切り替える。
# このスクリプトは本番トラフィックに影響する変更操作を実行するため、--approve を必須とする。
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: switchover_blue_green_deployment.sh --config FILE --blue-green-deployment-id ID --approve [options]
  --config FILE                    環境別設定ファイル（必須）
  --blue-green-deployment-id ID  切替対象の Blue/Green Deployment 識別子（必須）
  --approve                      検証完了後の切替を明示承認する必須フラグ
  --switchover-timeout SEC       RDS に渡す切替タイムアウト秒数（default: 300）
  --region REGION                AWS Region（設定ファイルの aws_region を上書き）
  --profile PROFILE              AWS CLI profile（省略時は AWS CLI の既定認証情報）
  --output-dir DIR               応答 JSON の保存先（default: temporary directory）
USAGE
}

config=''; deployment_identifier=''; approve=false; switchover_timeout=300; region=''; profile=''; output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --blue-green-deployment-id) deployment_identifier=${2:?}; shift 2 ;;
    --approve) approve=true; shift ;;
    --switchover-timeout) switchover_timeout=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" ]] || { echo '--config is required.' >&2; exit 2; }
[[ -n "$deployment_identifier" ]] || { echo '--blue-green-deployment-id is required.' >&2; exit 2; }
[[ "$approve" == true ]] || { echo '--approve is required because switchover changes production routing.' >&2; exit 2; }
[[ "$switchover_timeout" =~ ^[0-9]+$ ]] || { echo '--switchover-timeout must be an integer.' >&2; exit 2; }

[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-switchover.XXXXXX")
mkdir -p "$output_dir"
# config から環境に紐づく AWS CLI のリージョン・プロファイルを取得する。AWS API は呼び出さない。
config_aws=$(python3 -c 'import json,sys,yaml; d=yaml.safe_load(open(sys.argv[1])); d.get("aws_region") or (_ for _ in ()).throw(SystemExit(f"{sys.argv[1]}: aws_region が未定義です")); print(json.dumps({"region":d["aws_region"], "profile":d.get("aws_profile", "")}))' "$config")
[[ -n "$region" ]] || region=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["region"])' "$config_aws")
[[ -n "$profile" ]] || profile=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("profile", ""))' "$config_aws")
aws_args=(--region "$region")
[[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [切替前・読み取り] 対象 Deployment の現在状態を取得する。
# Green 構築と検証が完了した AVAILABLE 状態だけを切替対象にする。
aws "${aws_args[@]}" rds describe-blue-green-deployments \
  --blue-green-deployment-identifier "$deployment_identifier" \
  --output json > "$output_dir/before-switchover.json"
status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["BlueGreenDeployments"][0]["Status"])' "$output_dir/before-switchover.json")
[[ "$status" == 'AVAILABLE' ]] || { echo "Switchover requires AVAILABLE status; current status: $status" >&2; exit 1; }

# [変更] RDS の Blue/Green Deployment を切り替える。切替後は Green が本番 DB となる。
aws "${aws_args[@]}" rds switchover-blue-green-deployment \
  --blue-green-deployment-identifier "$deployment_identifier" \
  --switchover-timeout "$switchover_timeout" \
  --output json > "$output_dir/switchover-blue-green-deployment.json"

echo "Switchover started: $deployment_identifier"
echo "Artifacts: $output_dir"
echo "Monitor with: aws ${aws_args[*]} rds describe-blue-green-deployments --blue-green-deployment-identifier $deployment_identifier --output json"
