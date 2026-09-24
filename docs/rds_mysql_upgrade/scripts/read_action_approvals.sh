#!/usr/bin/env bash
# 設定ファイルの actions（承認宣言）を KEY=VALUE 形式で標準出力へ書き出す。
# AWS API は呼び出さない。config は読むだけで、書き戻しは行わない。
#
# 用途:
#   CodePipeline のステージ条件（BeforeEntry の VariableCheck）へ渡すために、
#   CodeBuild の exported-variables として公開する。これにより、承認していない
#   フェーズのステージ（手動承認を含む）をスキップできる。
#
#   承認ゲートそのものは従来どおり config の actions が持つ。本スクリプトは
#   その宣言をパイプラインから参照できるようにするだけであり、運用は変わらない。
#
# 出力例:
#   BUILD_APPROVED=approved
#   SWITCHOVER_APPROVED=pending
#   CLEANUP_APPROVED=pending
set -euo pipefail

usage() { echo 'Usage: read_action_approvals.sh --config FILE --service NAME'; }
config=''; service=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" ]] || { usage >&2; exit 2; }

# 未定義のアクションは pending として扱う（承認されていない側に倒す）。
ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
  BUILD_APPROVED=optional:service.actions.build=pending \
  SWITCHOVER_APPROVED=optional:service.actions.switchover=pending \
  CLEANUP_APPROVED=optional:service.actions.cleanup=pending
