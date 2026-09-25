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

# 設定の承認宣言だけを読む（読み取りは lib/deployment_config.rb）。AWS API は呼び出さない。
config_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
  build=optional:service.actions.build=pending)
eval "$config_vars"
[[ "$build" == approved ]] || { echo 'build: pending; no changes made.'; exit 0; }

# --region / --profile は空でもそのまま渡す（空なら Ruby 側が設定ファイルの値を使う）。
# 実行ビットに頼らず ruby へ明示的に渡す（CodePipeline の artifact で落ちうるため）。
common=(--config "$config" --service "$service" --region "$region" --profile "$profile")

# --- 第 1 層: フェーズガード（観測と判定は lib/migration_phase.rb）--------
phase_vars=$(ruby "$(dirname "$0")/lib/migration_phase.rb" observe "${common[@]}")
eval "$phase_vars"   # PHASE / CURRENT_VERSION / CURRENT_GROUP / SOURCE_ID
case "$PHASE" in
  post_switchover)
    # 切替済み。Deployment が cleanup 済みで存在しなくても新規作成へ進まない。
    echo "Migration already completed: $SOURCE_ID is ${CURRENT_VERSION} with ${CURRENT_GROUP}."
    exit 0 ;;
  unknown)
    echo '移行元が移行前・移行後のいずれの宣言とも一致しない。設定の誤りか想定外のドリフトである。' >&2
    exit 1 ;;
esac

# --- 第 2 層: Deployment の状態別分岐・保護スナップショット・作成 ----------
# create_blue_green_deployment.rb が行う（冒頭のコメントを参照）。
ruby "$(dirname "$0")/create_blue_green_deployment.rb" "${common[@]}" \
  --output-dir "$output_dir" --wait-timeout-seconds "$wait_timeout_seconds"
echo "Build completed. Artifacts: $output_dir"
