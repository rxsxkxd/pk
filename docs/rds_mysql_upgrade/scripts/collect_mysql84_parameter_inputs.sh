#!/usr/bin/env bash
# Step 2: MySQL 8.4 用パラメータグループ生成に必要な、AWS の読み取り結果だけを収集する。
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: collect_mysql84_parameter_inputs.sh --source-parameter-group NAME [options]
  --source-parameter-group NAME  Existing MySQL 8.0 custom parameter group (required)
  --db-instance-id ID            Optional: captures association/apply status for this instance
  --region REGION                AWS Region (default: AWS CLI configuration)
  --profile PROFILE              AWS CLI profile (default: AWS CLI configuration)
  --output-dir DIR               JSON output directory (default: temporary directory)
USAGE
}

source_pg=''; db_instance_id=''; region=''; profile=''; output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-parameter-group) source_pg=${2:?}; shift 2 ;;
    --db-instance-id) db_instance_id=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$source_pg" ]] || { echo '--source-parameter-group is required.' >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-mysql84-parameters.XXXXXX")
mkdir -p "$output_dir"
aws_args=()
[[ -n "$region" ]] && aws_args+=(--region "$region")
[[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [P1-01] 対象 8.0 パラメータグループの family・名前・説明を取得する。
aws "${aws_args[@]}" rds describe-db-parameter-groups \
  --db-parameter-group-name "$source_pg" --output json > "$output_dir/source-parameter-group.json"

# [P1-02] 現行グループで利用者が明示設定した値だけを取得する。
# 8.4 YAML の候補と移行ルール照合の入力に使う。AWS CLI の自動ページネーションを有効のまま使う。
aws "${aws_args[@]}" rds describe-db-parameters \
  --db-parameter-group-name "$source_pg" --source user --output json > "$output_dir/source-user-parameters.json"

# [P1-03] 現行 8.0 カスタムグループで RDS が system として返す値を取得する。
# インスタンスクラス等により RDS が決定する値を、engine default と区別して Ruby レポートに記載する。
aws "${aws_args[@]}" rds describe-db-parameters \
  --db-parameter-group-name "$source_pg" --source system --output json > "$output_dir/source-system-parameters.json"

# [P1-04] mysql8.0 ファミリーの engine default を取得する。
# Source=system の実効値ではない。現行 user 値がエンジン既定値を上書きしているかを Ruby で報告する。
aws "${aws_args[@]}" rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.0 --output json > "$output_dir/mysql80-default-parameters.json"

# [P1-05] mysql8.4 ファミリーの engine default を取得する。
# まだ DB に関連付けない Phase 1 では Source=system は確定しない。パラメータの存否、変更可否、許容値、
# engine default を確認し、8.0 の値を無条件にコピーしないために使う。
aws "${aws_args[@]}" rds describe-engine-default-parameters \
  --db-parameter-group-family mysql8.4 --output json > "$output_dir/mysql84-default-parameters.json"

if [[ -n "$db_instance_id" ]]; then
  # [P1-06] 任意。現行 DB へのグループ関連付けと ParameterApplyStatus を取得する。
  # 収集対象グループとインスタンスが一致するか、pending-reboot 等がないかを Ruby で報告する。
  aws "${aws_args[@]}" rds describe-db-instances \
    --db-instance-identifier "$db_instance_id" --output json > "$output_dir/source-db-instance.json"
fi

# GNU date 前提（他スクリプトと同じ ISO8601 形式）。source_pg は AWS リソース識別子で文字種が限定されるため直接埋め込む。
printf '{"source_parameter_group":"%s","collected_at":"%s"}\n' "$source_pg" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$output_dir/metadata.json"
echo "Collected read-only AWS CLI results: $output_dir"
echo "Generate: ruby scripts/generate_mysql84_parameter_group.rb --input-dir $output_dir --output-dir <generated-dir> --system <system> --environment <environment>"
