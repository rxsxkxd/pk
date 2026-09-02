#!/usr/bin/env bash
# Step 7: 承認済みの後始末（Blue/Green Deployment と旧 Blue の削除）を行う。
# 削除は不可逆な変更操作のため、実行前に次を確認する。
#   1. 設定ファイルの actions.cleanup が approved であること
#   2. Deployment が SWITCHOVER_COMPLETED であること
#   3. 旧 Blue（<source>-old1）の削除保護が無効であること
#   4. [--mysql-user 指定時のみ] 旧 Blue に逆方向レプリケーション（新 Blue → 旧 Blue）が
#      張られていないこと。RDS の外部レプリケーション（mysql.rds_set_external_source）は
#      describe-db-instances 等の読み取り API には反映されないため、DB へ接続してしか判定できない。
#      本番 DB 認証情報を CI に常設しない方針のため、このチェックは任意（既定でスキップ）とする。
#      CI 実行では検証されないので、承認前に一度ローカルから --mysql-user 付きで実行し、
#      逆レプリが残っていないことを確認してから actions.cleanup を approved にすること。
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: cleanup.sh --config FILE --service NAME [options]
  --config FILE               環境別設定ファイル（必須）
  --service NAME              config の services 配下に定義したサービス名（必須）
  --mysql-user USER           逆方向レプリケーション確認のための旧 Blue への接続ユーザー（任意）
  --mysql-password-env NAME   パスワードを渡す環境変数名（default: MYSQL_PASSWORD）
  --ssl-ca FILE                RDS CA bundle（指定時は ssl-mode=VERIFY_CA で接続）
  --region REGION              AWS Region（設定ファイルの aws_region を上書き）
  --profile PROFILE            AWS CLI profile（省略時は AWS CLI の既定認証情報）
  --output-dir DIR             応答 JSON の保存先（default: temporary directory）
USAGE
}

config=''; service=''; mysql_user=''; mysql_password_env='MYSQL_PASSWORD'; ssl_ca=''
region=''; profile=''; output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config=${2:?}; shift 2 ;;
    --service) service=${2:?}; shift 2 ;;
    --mysql-user) mysql_user=${2:?}; shift 2 ;;
    --mysql-password-env) mysql_password_env=${2:?}; shift 2 ;;
    --ssl-ca) ssl_ca=${2:?}; shift 2 ;;
    --region) region=${2:?}; shift 2 ;;
    --profile) profile=${2:?}; shift 2 ;;
    --output-dir) output_dir=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$config" && -n "$service" ]] || { usage >&2; exit 2; }
[[ -n "$output_dir" ]] || output_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-bg-cleanup.XXXXXX")
mkdir -p "$output_dir"

# YAML の読み込みは 1 回だけ行い、以降は python3 -c を呼ばずシェル変数として使う。
eval "$(python3 -c '
import shlex, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = d["services"][sys.argv[2]]
a = s.get("actions", {})
if not s.get("source_db_instance_identifier"):
    sys.exit("missing source_db_instance_identifier")
values = {
    "cleanup_approved": a.get("cleanup", "pending"),
    "source_id": s["source_db_instance_identifier"],
    "config_region": d["aws_region"],
}
for k, v in values.items():
    print(f"{k}={shlex.quote(str(v))}")
' "$config" "$service")"
[[ "$cleanup_approved" == approved ]] || { echo 'cleanup: pending; no changes made.'; exit 0; }
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

# [読み取り] Source に紐づく Deployment を検索する。設定値ではなく AWS の実状態から対象を解決する。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" --output json > "$output_dir/source.json" 2>/dev/null || true
source_arn=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --query 'DBInstances[0].DBInstanceArn' --output text 2>/dev/null || true)
if [[ -z "$source_arn" || "$source_arn" == None ]]; then
  echo "Source DB instance not found: $source_id" >&2
  exit 1
fi
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" --output json > "$output_dir/deployment.json"
deployment_id=$(aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
  --query 'BlueGreenDeployments[0].BlueGreenDeploymentIdentifier' --output text)

if [[ -z "$deployment_id" || "$deployment_id" == None ]]; then
  echo "Blue/Green Deployment not found. Already cleaned up."
  echo "Artifacts: $output_dir"
  exit 0
fi

status=$(aws "${aws_args[@]}" rds describe-blue-green-deployments --blue-green-deployment-identifier "$deployment_id" \
  --query 'BlueGreenDeployments[0].Status' --output text)
[[ "$status" == SWITCHOVER_COMPLETED ]] || { echo "Cleanup requires SWITCHOVER_COMPLETED status; current status: $status" >&2; exit 1; }

# 旧 Blue の識別子は AWS から引き当てる。RDS はスイッチオーバー時に <source>-old1 へ自動リネームする。
old_blue_id="${source_id}-old1"
if ! aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$old_blue_id" --output json > "$output_dir/old-blue.json" 2>/dev/null; then
  echo "Old Blue ($old_blue_id) not found. Deleting the Deployment only."
  aws "${aws_args[@]}" rds delete-blue-green-deployment --blue-green-deployment-identifier "$deployment_id" --output json > "$output_dir/delete-blue-green-deployment.json"
  echo "Deployment deleted: $deployment_id"
  echo "Artifacts: $output_dir"
  exit 0
fi

deletion_protection=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$old_blue_id" \
  --query 'DBInstances[0].DeletionProtection' --output text)
[[ "$deletion_protection" == False ]] || { echo "Deletion protection is enabled on $old_blue_id. Disable it before cleanup." >&2; exit 1; }

# [DB 読み取り・任意] 旧 Blue に逆方向レプリケーションが張られていないかを確認する。
# performance_schema の SERVICE_STATE を見る（SHOW REPLICA STATUS の文言はバージョンで揺れるため）。
# --mysql-user 未指定（CI からの通常実行を含む）の場合はチェックをスキップし、警告だけ出す。
if [[ -n "$mysql_user" ]]; then
  old_blue_endpoint=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$old_blue_id" \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  sql="SELECT IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_connection_status LIMIT 1),'NONE'), IFNULL((SELECT SERVICE_STATE FROM performance_schema.replication_applier_status LIMIT 1),'NONE');"
  mysql_args=(--batch --skip-column-names --raw --host="$old_blue_endpoint" --user="$mysql_user")
  [[ -n "$ssl_ca" ]] && mysql_args+=(--ssl-mode=VERIFY_CA --ssl-ca="$ssl_ca")
  if [[ -n "${!mysql_password_env:-}" ]]; then
    replication_state=$(env "MYSQL_PWD=${!mysql_password_env}" mysql "${mysql_args[@]}" --execute="$sql")
  else
    replication_state=$(mysql "${mysql_args[@]}" --password --execute="$sql")
  fi
  io_state=$(cut -f1 <<< "$replication_state")
  sql_state=$(cut -f2 <<< "$replication_state")
  echo "Reverse replication state on $old_blue_id: IO=$io_state SQL=$sql_state"
  if [[ "$io_state" != "NONE" && "$io_state" != "OFF" ]] || [[ "$sql_state" != "NONE" && "$sql_state" != "OFF" ]]; then
    echo "Reverse replication is still active on $old_blue_id. Aborting cleanup." >&2
    exit 1
  fi
else
  echo "WARNING: --mysql-user not given; reverse replication was not checked. This check does not run in CI (no production DB credentials are stored there); confirm manually from a local run before approving cleanup." >&2
fi

final_snapshot_id="${source_id}-final-$(date -u +%Y%m%d%H%M%S)"

# [変更] Blue/Green Deployment を削除する。Green（切替後の本番）はそのまま残る。
aws "${aws_args[@]}" rds delete-blue-green-deployment --blue-green-deployment-identifier "$deployment_id" --output json > "$output_dir/delete-blue-green-deployment.json"

# [変更] 旧 Blue を最終スナップショット付きで削除する。不可逆な操作。
aws "${aws_args[@]}" rds delete-db-instance --db-instance-identifier "$old_blue_id" \
  --final-db-snapshot-identifier "$final_snapshot_id" --output json > "$output_dir/delete-db-instance.json"

echo "Deployment deleted: $deployment_id"
echo "Old Blue deletion started: $old_blue_id (final snapshot: $final_snapshot_id)"
echo "Artifacts: $output_dir"
