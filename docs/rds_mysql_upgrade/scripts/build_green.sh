#!/usr/bin/env bash
# Step 3: 承認済みの保護スナップショット取得と Blue/Green Green 環境の作成を行う。
#
# 冪等性の担保は二層で行う。
#   ① フェーズガード: 移行元のエンジンバージョンとパラメータグループを見て、
#      既に切替済み（＝ build の対象ではない）かを判定する。cleanup 完了後に
#      build: approved のまま再実行しても、新規作成へ進まずに完了を報告する。
#   ② 状態機械: Deployment の Status で分岐する。PROVISIONING / AVAILABLE /
#      INVALID_CONFIGURATION はいずれも移行元が 8.0 のまま起こるため、
#      ① では区別できない。このフェーズでは ② が本体である。
#
# 終了コードの意味:
#   0 望ましい終了状態（AVAILABLE な Deployment が存在する）に到達している
#   1 到達しておらず、自動では到達できない
#   2 引数の誤り
set -euo pipefail

# shellcheck source=lib/deployment_config.sh
source "$(dirname "$0")/lib/deployment_config.sh"

usage() {
  cat <<'USAGE'
Usage: build_green.sh --config FILE --service NAME [options]
  --config FILE      環境別設定ファイル（必須）
  --service NAME     config の services 配下に定義したサービス名（必須）
  --region REGION    AWS Region（設定ファイルの aws_region を上書き）
  --profile PROFILE  AWS CLI profile（省略時は AWS CLI の既定認証情報）
  --output-dir DIR   応答 JSON の保存先（default: temporary directory）
  --wait-timeout-seconds SEC  AVAILABLE 待機の上限秒数（default: 3600）
USAGE
}

# Blue/Green Deployment が AVAILABLE になるまで待つ。
# AWS CLI に Blue/Green 用の waiter は存在しないため、明示的にポーリングする。
wait_for_available() {
  local deployment_id=$1
  local deadline=$(( $(date +%s) + wait_timeout_seconds ))
  local status
  while true; do
    status=$(aws "${aws_args[@]}" rds describe-blue-green-deployments \
      --blue-green-deployment-identifier "$deployment_id" \
      --query 'BlueGreenDeployments[0].Status' --output text)
    case "$status" in
      AVAILABLE)
        echo "Blue/Green Deployment is available: $deployment_id"
        return 0 ;;
      PROVISIONING)
        echo "  status: $status" ;;
      *)
        echo "Blue/Green Deployment did not become available; status: $status" >&2
        return 1 ;;
    esac
    [[ $(date +%s) -lt $deadline ]] || { echo "Timed out waiting for AVAILABLE." >&2; return 1; }
    sleep 30
  done
}

config=''; service=''; region=''; profile=''; output_dir=''
wait_timeout_seconds=3600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    --wait-timeout-seconds) wait_timeout_seconds=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" ]] || { usage >&2; exit 2; }
[[ "$wait_timeout_seconds" =~ ^[0-9]+$ ]] || { echo '--wait-timeout-seconds must be an integer.' >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-build.XXXXXX")
mkdir -p "$output_dir"

# shellcheck source=lib/migration_phase.sh
source "$(dirname "$0")/lib/migration_phase.sh"

# 設定ファイルの承認宣言と、スナップショット・移行元 DB の識別子を取得する。AWS API は呼び出さない。
# 設定の読み込みは 1 回だけ行い、以降はシェル変数として使う。
# 必要な項目とその必須・任意だけをここに宣言する（共通関数は lib/deployment_config.sh）。
eval "$(deployment_config_vars "$config" "$service" '
  service($service) as $svc | $svc.actions as $actions | {
    build:                          optional($actions.build; "pending"),
    source_id:                      required("source_db_instance_identifier"; $svc.source_db_instance_identifier),
    snapshot_id:                    required("protection_snapshot_identifier"; $svc.protection_snapshot_identifier),
    source_engine_version:          required("source_engine_version"; $svc.source_engine_version),
    source_db_parameter_group_name: required("source_db_parameter_group_name"; $svc.source_db_parameter_group_name),
    target_engine_version:          required("target_engine_version"; $svc.target_engine_version),
    target_db_parameter_group_name: required("target_db_parameter_group_name"; $svc.target_db_parameter_group_name),
    config_region:                  required("aws_region"; .aws_region),
  } | shellvars')"
[[ "$build" == approved ]] || { echo 'build: pending; no changes made.'; exit 0; }
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# --- 第 1 層: フェーズガード -----------------------------------------------
# アーカイブ用の JSON 保存とは別に、--query/--output text で値だけを取得する
# （読み取り専用 API なので呼び直しても安全）。
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
    # 切替済み。Deployment が cleanup 済みで存在しなくても新規作成へ進まない。
    echo "Migration already completed: $source_id is ${current_version} with ${current_group}."
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

# --- 第 2 層: Deployment の状態別分岐 --------------------------------------
source_arn=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --query 'DBInstances[0].DBInstanceArn' --output text)
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
  --output json > "$output_dir/deployments.json"
read -r existing_id existing_status <<< "$(
  aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
    --query 'BlueGreenDeployments[0].[BlueGreenDeploymentIdentifier,Status]' --output text
)"

if [[ -n "$existing_id" && "$existing_id" != None ]]; then
  case "$existing_status" in
    AVAILABLE)
      echo "Blue/Green Deployment already available: $existing_id"
      echo "Artifacts: $output_dir"
      exit 0
      ;;
    PROVISIONING)
      # 作成途中。二重作成せず AVAILABLE を待つ。
      # Blue/Green Deployment 用の waiter は AWS CLI に存在しないため
      # （RDS の waiter は DBInstance / DBSnapshot 系のみ）、明示的にポーリングする。
      echo "Blue/Green Deployment is provisioning: $existing_id"
      wait_for_available "$existing_id"
      echo "Artifacts: $output_dir"
      exit 0
      ;;
    *)
      # INVALID_CONFIGURATION / SWITCHOVER_FAILED / DELETING など。
      # 「存在するから成功」と扱うと、失敗した Deployment が残る限り
      # 永久に成功を返し続ける（サイレント失敗）。ここで止める。
      echo "Blue/Green Deployment exists but is not usable: $existing_id (status: $existing_status)" >&2
      echo "内容を確認し、不要であれば削除してから再実行する。" >&2
      exit 1
      ;;
  esac
fi

# --- 保護スナップショット ---------------------------------------------------
# 存在の有無だけでなく Status を見る。failed のまま待つと無駄にブロックされる。
snapshot_status=$(aws "${aws_args[@]}" rds describe-db-snapshots \
  --db-snapshot-identifier "$snapshot_id" \
  --query 'DBSnapshots[0].Status' --output text 2>/dev/null || echo '')

case "$snapshot_status" in
  '' | None)
    # [変更] 保護スナップショットを作成する。切り戻し可能な状態を確保するための操作。
    aws "${aws_args[@]}" rds create-db-snapshot \
      --db-instance-identifier "$source_id" --db-snapshot-identifier "$snapshot_id" \
      --output json > "$output_dir/create-snapshot.json"
    ;;
  available)
    echo "Protection snapshot already available: $snapshot_id"
    ;;
  creating)
    echo "Protection snapshot is being created: $snapshot_id"
    ;;
  *)
    echo "Protection snapshot is in an unusable state: $snapshot_id (status: $snapshot_status)" >&2
    echo "削除して作り直すか、別の識別子を config に指定する。" >&2
    exit 1
    ;;
esac

# [読み取り待機] 保護スナップショットが available になるまで待ち、作成前の復旧可能性を確定する。
aws "${aws_args[@]}" rds wait db-snapshot-available --db-snapshot-identifier "$snapshot_id"
aws "${aws_args[@]}" rds describe-db-snapshots --db-snapshot-identifier "$snapshot_id" \
  --output json > "$output_dir/snapshot.json"

create_args=(--config "$config" --service "$service" --region "$region" --output-dir "$output_dir/blue-green")
[[ -n "$profile" ]] && create_args+=(--profile "$profile")
"$(dirname "$0")/create_blue_green_deployment.sh" "${create_args[@]}"
echo "Build completed. Artifacts: $output_dir"
