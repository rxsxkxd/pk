#!/usr/bin/env bash
# Step 5: 設定ファイルの switchover: approved を前提に、Blue/Green を切り替える。
#
# 冪等性の担保は二層で行う。
#   ① 結果の観測: 移行元インスタンスのエンジンバージョンとパラメータグループ。
#      切替後は <source_id> が green（8.4 + 新 PG）を指すため、切替の有無が直接現れる。
#      Deployment が cleanup で削除された後も判定できる。
#   ② 安全弁: Deployment の Status。SWITCHOVER_IN_PROGRESS 中の再入を防ぐ。
#      リネームは切替処理の完了時に行われるため、進行中は ① だけでは
#      「まだ切替前」と誤認して API を二重に呼ぶ。
#
# 終了コードの意味:
#   0 望ましい終了状態（切替完了）に到達している。実行したかは問わない
#   1 到達しておらず、自動では到達できない
#   2 引数の誤り
set -euo pipefail

# shellcheck source=lib/deployment_config.sh
source "$(dirname "$0")/lib/deployment_config.sh"

usage() {
  cat <<'USAGE'
Usage: switchover.sh --config FILE --service NAME --approve [options]
  --config FILE               環境別設定ファイル（必須）
  --service NAME              config の services 配下に定義したサービス名（必須）
  --approve                   本番トラフィックに影響する操作を明示承認する必須フラグ
  --region REGION             AWS Region（設定ファイルの aws_region を上書き）
  --profile PROFILE           AWS CLI profile（省略時は AWS CLI の既定認証情報）
  --output-dir DIR            応答 JSON の保存先（default: temporary directory）
  --wait-timeout-seconds SEC  切替完了待機の上限秒数（default: 1800）
USAGE
}

config=''; service=''; approve=false; region=''; profile=''; output_dir=''
wait_timeout_seconds=1800
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --approve) approve=true; shift ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    --wait-timeout-seconds) wait_timeout_seconds=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" && "$approve" == true ]] || { usage >&2; exit 2; }
[[ "$wait_timeout_seconds" =~ ^[0-9]+$ ]] || { echo '--wait-timeout-seconds must be an integer.' >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-switchover-step.XXXXXX")
mkdir -p "$output_dir"

# shellcheck source=lib/migration_phase.sh
source "$(dirname "$0")/lib/migration_phase.sh"

# 設定の読み込みは 1 回だけ行い、以降はシェル変数として使う。
# 必要な項目とその必須・任意だけをここに宣言する（共通関数は lib/deployment_config.sh）。
deployment_config_eval "$config" "$service" '
  service($service) as $svc | $svc.actions as $actions | {
    approved:                       optional($actions.switchover; "pending"),
    timeout:                        optional($actions.switchover_timeout; 300),
    source_id:                      required("source_db_instance_identifier"; $svc.source_db_instance_identifier),
    source_engine_version:          required("source_engine_version"; $svc.source_engine_version),
    source_db_parameter_group_name: required("source_db_parameter_group_name"; $svc.source_db_parameter_group_name),
    target_engine_version:          required("target_engine_version"; $svc.target_engine_version),
    target_db_parameter_group_name: required("target_db_parameter_group_name"; $svc.target_db_parameter_group_name),
    config_region:                  required("aws_region"; .aws_region),
  } | shellvars'
[[ "$approved" == approved ]] || { echo 'switchover: pending; no changes made.'; exit 0; }
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# --- 第 1 層: 結果の観測 ---------------------------------------------------
# [読み取り] 移行元識別子が指す実体のエンジンバージョンとパラメータグループを見る。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --output json > "$output_dir/source.json"
read -r current_version current_group <<< "$(
  aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
    --query 'DBInstances[0].[EngineVersion,DBParameterGroups[0].DBParameterGroupName]' --output text
)"

phase=$(resolve_migration_phase "$current_version" "$current_group" \
  "$source_engine_version" "$source_db_parameter_group_name" \
  "$target_engine_version" "$target_db_parameter_group_name")

case "$phase" in
  post_switchover)
    # Deployment が cleanup 済みで存在しなくても、ここで完了と判定できる。
    echo "Switchover already completed: $source_id is ${current_version} with ${current_group}."
    echo "Artifacts: $output_dir"
    exit 0
    ;;
  unknown)
    echo "移行元が移行前・移行後のいずれの宣言とも一致しない。設定の誤りか想定外のドリフトである。" >&2
    describe_migration_phase_inputs "$current_version" "$current_group" \
      "$source_engine_version" "$source_db_parameter_group_name" \
      "$target_engine_version" "$target_db_parameter_group_name" >&2
    exit 1
    ;;
esac

# --- 第 2 層: 安全弁（Deployment の状態）-----------------------------------
# [読み取り] Source に紐づく Deployment を検索する。設定値ではなく AWS の実状態から対象を解決する。
source_arn=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --query 'DBInstances[0].DBInstanceArn' --output text)
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
  --output json > "$output_dir/deployment.json"
read -r deployment_id deployment_status <<< "$(
  aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
    --query 'BlueGreenDeployments[0].[BlueGreenDeploymentIdentifier,Status]' --output text
)"

if [[ -z "$deployment_id" || "$deployment_id" == None ]]; then
  # 移行前なのに Deployment がない。Step 3 が未実行か、誤って削除されている。
  echo "Blue/Green Deployment not found for $source_id (phase: pre_switchover)." >&2
  echo "Step 3（build_green.sh）が完了しているか確認する。" >&2
  exit 1
fi

# 切替完了を待つ。exit 0 が「望ましい終了状態に到達した」ことを意味するようにする。
wait_for_switchover() {
  local deadline=$(( $(date +%s) + wait_timeout_seconds ))
  local status
  while true; do
    status=$(aws "${aws_args[@]}" rds describe-blue-green-deployments \
      --blue-green-deployment-identifier "$deployment_id" \
      --query 'BlueGreenDeployments[0].Status' --output text)
    case "$status" in
      SWITCHOVER_COMPLETED)
        echo "Switchover completed: $deployment_id"
        return 0 ;;
      SWITCHOVER_IN_PROGRESS)
        echo "  status: $status" ;;
      *)
        echo "Switchover did not complete; status: $status" >&2
        return 1 ;;
    esac
    [[ $(date +%s) -lt $deadline ]] || { echo "Timed out waiting for SWITCHOVER_COMPLETED." >&2; return 1; }
    sleep 15
  done
}

case "$deployment_status" in
  AVAILABLE)
    args=(--config "$config" --blue-green-deployment-id "$deployment_id" --approve
          --switchover-timeout "$timeout" --region "$region" --output-dir "$output_dir/result")
    [[ -n "$profile" ]] && args+=(--profile "$profile")
    # 実行ビットに頼らず ruby へ明示的に渡す（CodePipeline の artifact で落ちうるため）。
    ruby "$(dirname "$0")/switchover_blue_green_deployment.rb" "${args[@]}"
    wait_for_switchover
    ;;
  SWITCHOVER_IN_PROGRESS)
    # 既に切替が走っている。二重に API を呼ばず完了だけを待つ。
    echo "Switchover already in progress: $deployment_id"
    wait_for_switchover
    ;;
  *)
    echo "Switchover requires AVAILABLE status; current status: $deployment_status" >&2
    exit 1
    ;;
esac

echo "Artifacts: $output_dir"
