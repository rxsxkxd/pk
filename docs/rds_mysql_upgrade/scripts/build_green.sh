#!/usr/bin/env bash
# Step 3: 承認済みの保護スナップショット取得と Blue/Green Green 環境の作成を行う。
#
# 冪等性の担保は二層で行う。
#   ① フェーズガード（ここ）: 移行元のエンジンバージョンとパラメータグループを見て、
#      既に切替済み（＝ build の対象ではない）かを判定する。cleanup 完了後に
#      build: approved のまま再実行しても、新規作成へ進まずに完了を報告する。
#   ② 状態機械（create_blue_green_deployment.rb）: Deployment の Status で分岐し、
#      無ければ保護スナップショットを確保して作成、PROVISIONING なら待つ。
#      PROVISIONING / AVAILABLE / INVALID_CONFIGURATION はいずれも移行元が 8.0 の
#      まま起こるため ① では区別できない。このフェーズでは ② が本体である。
#
# 終了コードの意味:
#   0 望ましい終了状態（AVAILABLE な Deployment が存在する）に到達している
#   1 到達しておらず、自動では到達できない
#   2 引数の誤り
set -euo pipefail

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

# 移行フェーズの判定（冪等性の第 1 層）は Ruby の 1 本で実装してある。
# resolve で pre_switchover / post_switchover / unknown を返し、
# describe で判定に使った実測値と宣言値を人向けに出す。
migration_phase=(ruby "$(dirname "$0")/lib/migration_phase.rb")

# 設定ファイルの承認宣言と、フェーズ判定に使う宣言値を取得する。AWS API は呼び出さない。
# 設定の読み込みは 1 回だけ行い、以降はシェル変数として使う。
# 必要な項目とその必須・任意だけをここに宣言する（読み取りは lib/deployment_config.rb）。
config_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
  build=optional:service.actions.build=pending \
  source_id=required:service.source_db_instance_identifier \
  source_engine_version=required:service.source_engine_version \
  source_db_parameter_group_name=required:service.source_db_parameter_group_name \
  target_engine_version=required:service.target_engine_version \
  target_db_parameter_group_name=required:service.target_db_parameter_group_name \
  config_region=required:aws_region)
eval "$config_vars"
[[ "$build" == approved ]] || { echo 'build: pending; no changes made.'; exit 0; }
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# --- 第 1 層: フェーズガード -----------------------------------------------
# [読み取り] 移行元の実体を見る。応答 JSON は create_blue_green_deployment.rb が保存する。
read -r current_version current_group <<< "$(
  aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
    --query 'DBInstances[0].[EngineVersion,DBParameterGroups[0].DBParameterGroupName]' --output text
)"

phase=$("${migration_phase[@]}" resolve "$current_version" "$current_group" \
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
    "${migration_phase[@]}" describe "$current_version" "$current_group" \
      "$source_engine_version" "$source_db_parameter_group_name" \
      "$target_engine_version" "$target_db_parameter_group_name" >&2
    exit 1
    ;;
esac

# --- 第 2 層: Deployment の状態別分岐・保護スナップショット・作成 ----------
# create_blue_green_deployment.rb が行う（冒頭のコメントを参照）。
# 実行ビットに頼らず ruby へ明示的に渡す（CodePipeline の artifact で落ちうるため）。
create_args=(--config "$config" --service "$service" --region "$region" --output-dir "$output_dir"
             --wait-timeout-seconds "$wait_timeout_seconds")
[[ -n "$profile" ]] && create_args+=(--profile "$profile")
ruby "$(dirname "$0")/create_blue_green_deployment.rb" "${create_args[@]}"
echo "Build completed. Artifacts: $output_dir"
