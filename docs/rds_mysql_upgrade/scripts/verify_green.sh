#!/usr/bin/env bash
# Step 4: Green の RDS 構成と ReplicaLag を AWS 読み取り API だけで検証する。
set -euo pipefail

# shellcheck source=lib/deployment_config.sh
source "$(dirname "$0")/lib/deployment_config.sh"

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

# shellcheck source=lib/migration_phase.sh
source "$(dirname "$0")/lib/migration_phase.sh"
# shellcheck source=lib/mysql_credentials.sh
source "$(dirname "$0")/lib/mysql_credentials.sh"

# 設定の読み込みは 1 回だけ行い、以降はシェル変数として使う。
# 必要な項目とその必須・任意だけをここに宣言する（共通関数は lib/deployment_config.sh）。
deployment_config_eval "$config" "$service" '
  service($service) as $svc | {
    source_id:                            required("source_db_instance_identifier"; $svc.source_db_instance_identifier),
    source_engine_version:                required("source_engine_version"; $svc.source_engine_version),
    source_db_parameter_group_name:       required("source_db_parameter_group_name"; $svc.source_db_parameter_group_name),
    target_engine_version:                required("target_engine_version"; $svc.target_engine_version),
    target_db_instance_class:             required("target_db_instance_class"; $svc.target_db_instance_class),
    target_db_parameter_group_name:       required("target_db_parameter_group_name"; $svc.target_db_parameter_group_name),
    target_parameter_group_template_path: required("target_parameter_group_template_path"; $svc.target_parameter_group_template_path),
    config_region:                        required("aws_region"; .aws_region),
  } | shellvars'
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [読み取り] 移行元識別子が指す実体を見て、検証すべきフェーズかを判定する。
# 切替後は <source_id> が green（新 Blue）を指すため、検証対象の Deployment は
# 既に SWITCHOVER_COMPLETED であり AVAILABLE ではない。そのままだと後始末フェーズで
# 再実行したときに必ず失敗するため、ここで「検証対象なし」として正常終了する。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" --output json > "$output_dir/source.json"
read -r current_version current_group <<< "$(
  aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
    --query 'DBInstances[0].[EngineVersion,DBParameterGroups[0].DBParameterGroupName]' --output text
)"
phase=$(resolve_migration_phase "$current_version" "$current_group" \
  "$source_engine_version" "$source_db_parameter_group_name" \
  "$target_engine_version" "$target_db_parameter_group_name")

if [[ "$phase" == post_switchover ]]; then
  echo "Already switched over: $source_id is ${current_version} with ${current_group}."
  echo 'Green の検証は切替前に行うものであり、検証対象はない。'
  echo "Artifacts: $output_dir"
  exit 0
fi

# [読み取り] Source ARN と、その Source に対応する Blue/Green Deployment を取得する。
source_arn=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --query 'DBInstances[0].DBInstanceArn' --output text)
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" --output json > "$output_dir/deployment.json"
read -r deployment_id target_arn status <<< "$(
  aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
    --query 'BlueGreenDeployments[0].[BlueGreenDeploymentIdentifier,Target,Status]' --output text
)"
if [[ -z "$deployment_id" || "$deployment_id" == None ]]; then
  echo "Blue/Green Deployment not found for $source_id" >&2
  echo "Step 3（build_green.sh）が未実行か、config の actions.build が pending の可能性がある。" >&2
  exit 1
fi
[[ "$status" == AVAILABLE ]] || { echo "Deployment is not AVAILABLE: $status" >&2; exit 1; }

# [読み取り] Green DB の状態を JSON で落とす。
# **突き合わせはここで行わない。**エンジン・インスタンスクラス・パラメータグループの
# 関連付けと適用状態・レプリカ遅延の判定は、すべてレポート生成器（--check）が行う。
# 判定ロジックをレポートと同じ場所へ集約し、レポートの内容と終了コードが
# 食い違わないようにするためである。このスクリプトは収集と受け渡しに徹する。
target_id=${target_arn##*:db:}
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$target_id" --output json > "$output_dir/green-db-instance.json"

# [DB 読み取り・任意] GitHub Environment Secret 等で接続情報が提供された場合、Green の
# MySQL 実効値を収集する。実効値はレポートにのみ掲載し、YAML との比較判定には使わない。
# [DB 読み取り・任意] Green の実効値を収集する。
# 接続方式は設定ファイルの mysql_verification が決める（parameter_store / plaintext /
# prompt）。--mysql-user を明示した場合は従来どおり呼び出し側の環境変数を使う。
read_mysql_verification_config "$config" "$service"
if [[ -n "$mysql_user" ]]; then
  # 後方互換: 呼び出し側が利用者とパスワード環境変数を直接指定した場合。
  MYSQL_VERIFY_USER="$mysql_user"
  MYSQL_VERIFY_PASSWORD="${!mysql_password_env:-}"
  MYSQL_VERIFY_ENABLED=true
elif [[ "$MYSQL_VERIFY_ENABLED" == true ]]; then
  resolve_mysql_credentials "$region" "$profile"
fi

# レポート生成器は Go 版だけである（decisions/implementation-language-policy.md）。
# CI は事前にビルドしたバイナリを GREEN_REPORT_GENERATOR で渡す。
# 指定がない場合はここでビルドする。go build の -o だけ絶対パスにすれば、
# 呼び出し元のカレントディレクトリに依存せず、引数の相対パスもそのまま通る。
#
# レポート生成より前に決めておく。MySQL 実効値の収集も、パラメータ名の抽出に
# 同じバイナリ（--list-parameter-names）を使うためである。
report_generator=${GREEN_REPORT_GENERATOR:-}
if [[ -z "$report_generator" ]]; then
  repository_root=$(cd "$(dirname "$0")/.." && pwd)
  report_generator=$(mktemp "${TMPDIR:-/tmp}/green-verification-report.XXXXXX")
  trap 'rm -f "$report_generator"' EXIT
  go -C "$repository_root" build -o "$report_generator" ./scripts/generate_green_verification_report
fi

# 実効値の収集も Go のバイナリで行う（MySQL クライアントを使わない）。
# CI は BuildReportTool が作ったものを GREEN_RUNTIME_COLLECTOR で受け取る。
runtime_collector=${GREEN_RUNTIME_COLLECTOR:-}

if [[ "$MYSQL_VERIFY_ENABLED" == true && -z "$runtime_values_file" ]]; then
  green_endpoint=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$target_id" \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  collect_args=(
    --template "$target_parameter_group_template_path"
    --host "$green_endpoint"
    --port "$MYSQL_VERIFY_PORT"
    --user "$MYSQL_VERIFY_USER"
    --password-env MYSQL_VERIFY_PASSWORD
    --output "$output_dir/green-runtime-values.json"
  )
  # TLS は常に検証する（証明書チェーンのみ。ホスト名は検証しない = VERIFY_CA 相当）。
  # 既定では収集バイナリへ焼き込んだ RDS のトラストストアを使うため、設定は要らない。
  # config の ssl_ca を指定した場合だけ、そのバンドルへ差し替える。
  [[ -n "$MYSQL_VERIFY_SSL_CA" ]] && collect_args+=(--ssl-ca "$MYSQL_VERIFY_SSL_CA")
  [[ -n "$runtime_collector" ]] && collect_args+=(--collector "$runtime_collector")
  export MYSQL_VERIFY_PASSWORD
  "$(dirname "$0")/collect_green_runtime_values.sh" "${collect_args[@]}"
  unset MYSQL_VERIFY_PASSWORD
  runtime_values_file="$output_dir/green-runtime-values.json"
fi

# [読み取り] Green に反映された Source=user / Source=system / 全パラメータを取得する。
# 後段のレポートで、Step 2 の CloudFormation YAML と Source=user を突き合わせる。
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$target_db_parameter_group_name" --source user --output json > "$output_dir/green-user-parameters.json"
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$target_db_parameter_group_name" --source system --output json > "$output_dir/green-system-parameters.json"
aws "${aws_args[@]}" rds describe-db-parameters --db-parameter-group-name "$target_db_parameter_group_name" --output json > "$output_dir/green-all-parameters.json"
# GNU date 前提（-d オプション）。本リポジトリの実行はいずれも GNU coreutils を含むコンテナ経由を想定する。
end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
# レプリカ遅延は JSON を落とすだけで、判定はレポート生成器が行う。
aws "${aws_args[@]}" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag --dimensions "Name=DBInstanceIdentifier,Value=$target_id" --statistics Maximum --period 60 --start-time "$start_time" --end-time "$end_time" --output json > "$output_dir/replica-lag.json"

# 検証とレポート生成をまとめて行う（--check と --output の併用）。
# 設定ファイルの宣言値を --expect-* で渡し、Green の実状態と突き合わせさせる。
# 不適合があればレポートの「0. 検証結果」に出たうえで、終了コード 1 が返る。
report_args=(
  --check
  --template "$target_parameter_group_template_path"
  --green-instance "$output_dir/green-db-instance.json"
  --deployment "$output_dir/deployment.json"
  --user-parameters "$output_dir/green-user-parameters.json"
  --system-parameters "$output_dir/green-system-parameters.json"
  --all-parameters "$output_dir/green-all-parameters.json"
  --replica-lag "$output_dir/replica-lag.json"
  --expect-engine-version "$target_engine_version"
  --expect-instance-class "$target_db_instance_class"
  --expect-parameter-group "$target_db_parameter_group_name"
  --output "$output_dir/green-verification-report.md"
)
[[ -n "$runtime_values_file" ]] && report_args+=(--runtime-values "$runtime_values_file")
if ! "$report_generator" "${report_args[@]}"; then
  echo "Artifacts: $output_dir"
  echo 'VERIFY FAILED: レポートの「0. 検証結果」を確認する。' >&2
  exit 1
fi
echo "VERIFY PASSED: $deployment_id"
echo "Artifacts: $output_dir"
