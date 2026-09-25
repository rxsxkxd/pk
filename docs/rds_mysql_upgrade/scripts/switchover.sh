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

usage() {
  cat <<'USAGE'
Usage: switchover.sh --config FILE --service NAME --approve [options]
  --config FILE               環境別設定ファイル（必須）
  --service NAME              config の services 配下に定義したサービス名（必須）
  --approve                   本番トラフィックに影響する操作を明示承認する必須フラグ
  --region REGION             AWS Region（設定ファイルの aws_region を上書き）
  --profile PROFILE           AWS CLI profile（省略時は AWS CLI の既定認証情報）
  --output-dir DIR            応答 JSON の保存先（default: temporary directory）
USAGE
}

config=''; service=''; approve=false; region=''; profile=''; output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --approve) approve=true; shift ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" && "$approve" == true ]] || { usage >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-switchover-step.XXXXXX")
mkdir -p "$output_dir"

# 設定の承認宣言だけを読む（読み取りは lib/deployment_config.rb）。AWS API は呼び出さない。
config_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
  approved=optional:service.actions.switchover=pending)
eval "$config_vars"
[[ "$approved" == approved ]] || { echo 'switchover: pending; no changes made.'; exit 0; }

# --region / --profile は空でもそのまま渡す（空なら Ruby 側が設定ファイルの値を使う）。
# 実行ビットに頼らず ruby へ明示的に渡す（CodePipeline の artifact で落ちうるため）。
common=(--config "$config" --service "$service" --region "$region" --profile "$profile")

# --- 第 1 層: 結果の観測（観測と判定は lib/migration_phase.rb）------------
phase_vars=$(ruby "$(dirname "$0")/lib/migration_phase.rb" observe "${common[@]}")
eval "$phase_vars"   # PHASE / CURRENT_VERSION / CURRENT_GROUP / SOURCE_ID
case "$PHASE" in
  post_switchover)
    # Deployment が cleanup 済みで存在しなくても、ここで完了と判定できる。
    echo "Switchover already completed: $SOURCE_ID is ${CURRENT_VERSION} with ${CURRENT_GROUP}."
    exit 0 ;;
  unknown)
    echo '移行元が移行前・移行後のいずれの宣言とも一致しない。設定の誤りか想定外のドリフトである。' >&2
    exit 1 ;;
esac

# --- 第 2 層: 安全弁（Deployment の状態）と切替・完了待ち -----------------
# switchover_blue_green_deployment.rb が行う（冒頭のコメントを参照）。
ruby "$(dirname "$0")/switchover_blue_green_deployment.rb" "${common[@]}" --approve \
  --output-dir "$output_dir"
