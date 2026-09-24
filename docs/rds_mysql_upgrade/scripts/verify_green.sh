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

# 移行フェーズの判定（冪等性の第 1 層）は Ruby の 1 本で実装してある。
# resolve で pre_switchover / post_switchover / unknown を返し、
# describe で判定に使った実測値と宣言値を人向けに出す。
migration_phase=(ruby "$(dirname "$0")/lib/migration_phase.rb")

# 設定の読み込みは 1 回だけ行い、以降はシェル変数として使う。
# 必要な項目とその必須・任意だけをここに宣言する（読み取りは lib/deployment_config.rb）。
config_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
  source_id=required:service.source_db_instance_identifier \
  source_engine_version=required:service.source_engine_version \
  source_db_parameter_group_name=required:service.source_db_parameter_group_name \
  target_engine_version=required:service.target_engine_version \
  target_db_instance_class=required:service.target_db_instance_class \
  target_db_parameter_group_name=required:service.target_db_parameter_group_name \
  target_parameter_group_template_path=required:service.target_parameter_group_template_path \
  config_region=required:aws_region)
eval "$config_vars"
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [読み取り] 移行元識別子が指す実体を見て、検証すべきフェーズかを判定する。
# 切替後は <source_id> が green（新 Blue）を指すため、検証対象の Deployment は
# 既に SWITCHOVER_COMPLETED であり AVAILABLE ではない。そのままだと後始末フェーズで
# 再実行したときに必ず失敗するため、ここで「検証対象なし」として正常終了する。
# フェーズ判定は build_green / switchover / cleanup と共有する（lib/migration_phase.rb）。
read -r current_version current_group <<< "$(
  aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
    --query 'DBInstances[0].[EngineVersion,DBParameterGroups[0].DBParameterGroupName]' --output text
)"
phase=$("${migration_phase[@]}" resolve "$current_version" "$current_group" \
  "$source_engine_version" "$source_db_parameter_group_name" \
  "$target_engine_version" "$target_db_parameter_group_name")
if [[ "$phase" == post_switchover ]]; then
  echo "Already switched over: $source_id is ${current_version} with ${current_group}."
  echo 'Green の検証は切替前に行うものであり、検証対象はない。'
  echo "Artifacts: $output_dir"
  exit 0
fi

# [読み取り] 検証に必要な AWS の状態を集める（Ruby。lib/green_state.rb）。
# Deployment を source の ARN で引き当て、Green・パラメータ 3 種・レプリカ遅延を
# $output_dir へ書き出す。Deployment が無い／AVAILABLE でなければここで止まる。
# **判定はしない。**判定は下の --check が行う。
# 同じ内容の Go 版（scripts/collect_green_state/）も残してある。
# 実行ビットに頼らず ruby へ明示的に渡す（CodePipeline の artifact で落ちうるため）。
state_args=(--region "$region" --source-id "$source_id"
            --target-parameter-group "$target_db_parameter_group_name" --output-dir "$output_dir")
[[ -n "$profile" ]] && state_args+=(--profile "$profile")
green_state=$(ruby "$(dirname "$0")/collect_green_state.rb" "${state_args[@]}")
eval "$green_state"   # DEPLOYMENT_ID / GREEN_INSTANCE_ID / GREEN_ENDPOINT

# [DB 読み取り・任意] Green の MySQL 実効値を収集する。レポートにのみ載せ、判定には使わない。
# 収集するか・接続情報（parameter_store / plaintext / prompt）の解決・収集の実行は
# collect_green_runtime_values.rb が設定ファイルの mysql_verification を読んで行う。
# 無効なら何もせず、出力ファイルも作らない。--runtime-values-file を渡せば収集しない。
if [[ -z "$runtime_values_file" ]]; then
  runtime_values="$output_dir/green-runtime-values.json"
  rm -f "$runtime_values"   # 前回の結果を今回の結果と取り違えないため
  runtime_args=(--config "$config" --service "$service" --host "$GREEN_ENDPOINT"
                --region "$region" --output "$runtime_values")
  [[ -n "$profile" ]] && runtime_args+=(--profile "$profile")
  [[ -n "$mysql_user" ]] && runtime_args+=(--mysql-user "$mysql_user" --mysql-password-env "$mysql_password_env")
  # 実行ビットに頼らず ruby へ明示的に渡す（CodePipeline の artifact で落ちうるため）。
  ruby "$(dirname "$0")/collect_green_runtime_values.rb" "${runtime_args[@]}"
  if [[ -f "$runtime_values" ]]; then runtime_values_file=$runtime_values; fi
fi

# 検証とレポート生成（Go。--check と --output の併用）。
# 収集結果は --input-dir で渡し、設定の宣言値は --expect-* で渡す。
# 不適合があればレポートの「0. 検証結果」に出たうえで、終了コード 1 が返る。
# CloudFormation テンプレートの読み取り（scripts/internal/cfn）を実効値の収集器と
# 共有するため、Go のままにしている。
# バイナリの場所は resolve_green_tools.rb が決める。CI は BuildReportTool が作ったものを
# GREEN_REPORT_GENERATOR で受け取る。指定が無いローカル実行でだけ、その場でビルドする。
green_tools=$(ruby "$(dirname "$0")/lib/resolve_green_tools.rb" --build-missing generate_green_verification_report)
eval "$green_tools"   # GREEN_REPORT_GENERATOR
report_args=(--check --input-dir "$output_dir"
             --template "$target_parameter_group_template_path"
             --expect-engine-version "$target_engine_version"
             --expect-instance-class "$target_db_instance_class"
             --expect-parameter-group "$target_db_parameter_group_name"
             --output "$output_dir/green-verification-report.md")
[[ -n "$runtime_values_file" ]] && report_args+=(--runtime-values "$runtime_values_file")
if ! "$GREEN_REPORT_GENERATOR" "${report_args[@]}"; then
  echo "Artifacts: $output_dir"
  echo 'VERIFY FAILED: レポートの「0. 検証結果」を確認する。' >&2
  exit 1
fi
echo "VERIFY PASSED: $DEPLOYMENT_ID"
echo "Artifacts: $output_dir"
