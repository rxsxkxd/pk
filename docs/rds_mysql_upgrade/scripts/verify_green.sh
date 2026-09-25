#!/usr/bin/env bash
# Step 4: Green の RDS 構成と ReplicaLag を AWS 読み取り API だけで検証する。
set -euo pipefail

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

# 準備（設定の読み取り・移行フェーズの観測・AWS の状態の収集・MySQL 実効値の収集）は
# prepare_green_verification.rb が行う。**判定はしない。**判定は下の --check が行う。
# --region / --profile / --runtime-values-file は空でもそのまま渡す（空なら Ruby 側が既定を使う）。
# 実行ビットに頼らず ruby へ明示的に渡す（CodePipeline の artifact で落ちうるため）。
prepare_args=(--config "$config" --service "$service" --output-dir "$output_dir"
              --region "$region" --profile "$profile" --runtime-values-file "$runtime_values_file")
[[ -n "$mysql_user" ]] && prepare_args+=(--mysql-user "$mysql_user" --mysql-password-env "$mysql_password_env")
prepared=$(ruby "$(dirname "$0")/prepare_green_verification.rb" "${prepare_args[@]}")
eval "$prepared"   # VERIFY / DEPLOYMENT_ID / TEMPLATE / EXPECT_* / RUNTIME_VALUES
[[ "$VERIFY" == run ]] || exit 0   # 切替済み。検証対象なし（理由は stderr に出ている）

# 検証とレポート生成（Go。--check と --output の併用）。
# 収集結果は --input-dir で渡し、設定の宣言値は --expect-* で渡す。
# 不適合があればレポートの「0. 検証結果」に出たうえで、終了コード 1 が返る。
# CloudFormation テンプレートの読み取り（scripts/internal/cfn）を実効値の収集器と
# 共有するため、Go のままにしている。
# バイナリの場所は resolve_green_tools.rb が決める。CI は BuildReportTool が作ったものを
# GREEN_REPORT_GENERATOR で受け取る。指定が無いローカル実行でだけ、その場でビルドする。
green_tools=$(ruby "$(dirname "$0")/lib/resolve_green_tools.rb" --build-missing generate_green_verification_report)
eval "$green_tools"   # GREEN_REPORT_GENERATOR
report_args=(--check --input-dir "$output_dir" --template "$TEMPLATE"
             --expect-engine-version "$EXPECT_ENGINE_VERSION"
             --expect-instance-class "$EXPECT_INSTANCE_CLASS"
             --expect-parameter-group "$EXPECT_PARAMETER_GROUP"
             --output "$output_dir/green-verification-report.md")
[[ -n "$RUNTIME_VALUES" ]] && report_args+=(--runtime-values "$RUNTIME_VALUES")
if ! "$GREEN_REPORT_GENERATOR" "${report_args[@]}"; then
  echo "Artifacts: $output_dir"
  echo 'VERIFY FAILED: レポートの「0. 検証結果」を確認する。' >&2
  exit 1
fi
echo "VERIFY PASSED: $DEPLOYMENT_ID"
echo "Artifacts: $output_dir"
