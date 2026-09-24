#!/usr/bin/env bash
# Step 7: 承認済みの後始末（Blue/Green Deployment と旧 Blue の削除）を行う。
#
# **パイプラインからは外し、人が実行するツールにした。**以前は CodePipeline の
# Cleanup ステージ（手動承認つき）から呼ばれていたが、旧 Blue の削除は不可逆で、
# 切り戻し不要の判断や逆方向レプリケーションの確認と一体で行うべき作業のため、
# 作業者が状況を確かめたうえで手で実行する。
#
# **実行には破壊的な権限が要る**（rds:DeleteBlueGreenDeployment / DeleteDBInstance /
# ModifyDBInstance / CreateDBSnapshot / AddTagsToResource）。パイプラインの実行ロールは
# もう持っていない。作業者がこの権限を持つロールを引き受けて実行する。
#
# 実行例:
#   tools/cleanup.sh --config config/blue-green/staging.deployment.yml --service example-service
#
# 冪等性の担保:
#   望ましい終了状態を「Deployment が存在せず、かつ旧 Blue が存在しない」と定義し、
#   2 つのリソースを独立に判定する。片方の完了を全体の完了とみなさない。
#
#   旧実装は「Deployment が無い → 既にクリーンアップ済み」で成功を返していた。
#   このため Deployment の削除に成功して旧 Blue の削除に失敗した場合、再実行が
#   「完了」と報告し、旧 Blue が残って課金が続く状態を見逃していた。
#
# 削除は不可逆な変更操作のため、実行前に次を確認する。
#   1. 設定ファイルの actions.cleanup が approved であること
#   2. 切替が完了していること
#      - Deployment が残っていれば Status == SWITCHOVER_COMPLETED
#      - Deployment が消えていれば移行元が「移行後」の姿（8.4 + 新 PG）であること
#   3. 旧 Blue（<source>-old1）の削除保護が無効であること
#   4. [--mysql-user 指定時のみ] 旧 Blue に逆方向レプリケーション（新 Blue → 旧 Blue）が
#      張られていないこと。RDS の外部レプリケーション（mysql.rds_set_external_source）は
#      describe-db-instances 等の読み取り API には反映されないため、DB へ接続してしか判定できない。
#      本番 DB 認証情報を CI に常設しない方針のため、このチェックは任意（既定でスキップ）とする。
#      CI 実行では検証されないので、承認前に一度ローカルから --mysql-user 付きで実行し、
#      逆レプリが残っていないことを確認してから actions.cleanup を approved にすること。
#
# 終了コードの意味:
#   0 望ましい終了状態（両リソースが存在しない、または削除処理中）に到達している
#   1 到達しておらず、自動では到達できない
#   2 引数の誤り
set -euo pipefail

# shellcheck source=lib/deployment_config.sh
# 設定の読み取りとフェーズ判定は scripts/lib/ のものを使う。**複製しない。**
# 特にフェーズ判定は冪等性の中核で、build_green / verify_green / switchover と
# 同じ実装（migration_phase.rb）でなければならない。
scripts_lib="$(cd "$(dirname "$0")/../scripts/lib" && pwd)"
source "$scripts_lib/deployment_config.sh"

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

# 移行フェーズの判定（冪等性の第 1 層）は Ruby の 1 本で実装してある。
# resolve で pre_switchover / post_switchover / unknown を返し、
# describe で判定に使った実測値と宣言値を人向けに出す。
migration_phase=(ruby "$scripts_lib/migration_phase.rb")

# 設定の読み込みは 1 回だけ行い、以降はシェル変数として使う。
# 必要な項目とその必須・任意だけをここに宣言する（共通関数は lib/deployment_config.sh）。
deployment_config_eval "$config" "$service" '
  service($service) as $svc | $svc.actions as $actions | {
    cleanup_approved:               optional($actions.cleanup; "pending"),
    source_id:                      required("source_db_instance_identifier"; $svc.source_db_instance_identifier),
    source_engine_version:          required("source_engine_version"; $svc.source_engine_version),
    source_db_parameter_group_name: required("source_db_parameter_group_name"; $svc.source_db_parameter_group_name),
    target_engine_version:          required("target_engine_version"; $svc.target_engine_version),
    target_db_parameter_group_name: required("target_db_parameter_group_name"; $svc.target_db_parameter_group_name),
    # 固定名にすることで、途中失敗後の再実行でスナップショットが増殖しない。
    final_snapshot_id:              optional($svc.final_snapshot_identifier; "\($svc.source_db_instance_identifier)-final"),
    config_region:                  required("aws_region"; .aws_region),
  } | shellvars'
[[ "$cleanup_approved" == approved ]] || { echo 'cleanup: pending; no changes made.'; exit 0; }
[[ -n "$region" ]] || region=$config_region
aws_args=(--region "$region"); [[ -n "$profile" ]] && aws_args+=(--profile "$profile")

old_blue_id="${source_id}-old1"

# --- 2 つのリソースの現在地を独立に把握する -------------------------------
# [読み取り] 移行元識別子が指す実体。切替後は green（新 Blue）を指す。
aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --output json > "$output_dir/source.json" 2>/dev/null || true
read -r current_version current_group <<< "$(
  aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
    --query 'DBInstances[0].[EngineVersion,DBParameterGroups[0].DBParameterGroupName]' \
    --output text 2>/dev/null || echo ' '
)"
if [[ -z "${current_version:-}" || "$current_version" == None ]]; then
  echo "Source DB instance not found: $source_id" >&2
  exit 1
fi
phase=$("${migration_phase[@]}" resolve "$current_version" "$current_group" \
  "$source_engine_version" "$source_db_parameter_group_name" \
  "$target_engine_version" "$target_db_parameter_group_name")

# [読み取り] Deployment。設定値ではなく AWS の実状態から対象を解決する。
source_arn=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$source_id" \
  --query 'DBInstances[0].DBInstanceArn' --output text)
aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
  --output json > "$output_dir/deployment.json"
read -r deployment_id deployment_status <<< "$(
  aws "${aws_args[@]}" rds describe-blue-green-deployments --filters "Name=source,Values=$source_arn" \
    --query 'BlueGreenDeployments[0].[BlueGreenDeploymentIdentifier,Status]' --output text
)"
[[ "$deployment_id" != None ]] || deployment_id=''

# [読み取り] 旧 Blue。RDS はスイッチオーバー時に <source>-old1 へ自動リネームする。
old_blue_status=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$old_blue_id" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo '')
if [[ -n "$old_blue_status" && "$old_blue_status" != None ]]; then
  aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$old_blue_id" \
    --output json > "$output_dir/old-blue.json"
else
  old_blue_status=''
fi

echo "現在地:"
echo "  移行フェーズ: $phase (${current_version} / ${current_group})"
echo "  Deployment:   ${deployment_id:-（無し）}${deployment_status:+ / $deployment_status}"
echo "  旧 Blue:      ${old_blue_id} ${old_blue_status:-（無し）}"

# --- 望ましい終了状態に到達済みか -----------------------------------------
if [[ -z "$deployment_id" && -z "$old_blue_status" ]]; then
  echo "Cleanup already completed: Deployment も 旧 Blue も存在しない。"
  echo "Artifacts: $output_dir"
  exit 0
fi

# --- 安全弁: 切替が完了していることを確認する -----------------------------
# Deployment が残っていれば Status で、消えていれば移行元の姿で確認する。
# これにより「Deployment 削除に成功し旧 Blue の削除に失敗した」状態からでも再開できる。
if [[ -n "$deployment_id" ]]; then
  case "$deployment_status" in
    SWITCHOVER_COMPLETED) ;;
    DELETING)
      echo "Deployment は削除処理中である: $deployment_id" ;;
    *)
      echo "Cleanup requires SWITCHOVER_COMPLETED status; current status: $deployment_status" >&2
      exit 1 ;;
  esac
elif [[ "$phase" != post_switchover ]]; then
  echo "Deployment が存在せず、かつ移行元が「移行後」の姿ではない。切替が完了していない可能性がある。" >&2
  "${migration_phase[@]}" describe "$current_version" "$current_group" \
    "$source_engine_version" "$source_db_parameter_group_name" \
    "$target_engine_version" "$target_db_parameter_group_name" >&2
  exit 1
fi

# --- 旧 Blue の削除 --------------------------------------------------------
case "$old_blue_status" in
  '')
    echo "旧 Blue は既に存在しない: $old_blue_id" ;;
  deleting)
    echo "旧 Blue は削除処理中である: $old_blue_id" ;;
  available)
    deletion_protection=$(aws "${aws_args[@]}" rds describe-db-instances --db-instance-identifier "$old_blue_id" \
      --query 'DBInstances[0].DeletionProtection' --output text)
    [[ "$deletion_protection" == False ]] || {
      echo "Deletion protection is enabled on $old_blue_id. Disable it before cleanup." >&2; exit 1; }

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

    # [変更] 旧 Blue を最終スナップショット付きで削除する。不可逆な操作。
    # 最終スナップショットが既に存在する場合は、以前の削除が進行済みであることを意味する。
    if aws "${aws_args[@]}" rds describe-db-snapshots --db-snapshot-identifier "$final_snapshot_id" \
        --output json > /dev/null 2>&1; then
      echo "最終スナップショットが既に存在する: $final_snapshot_id" >&2
      echo "以前の削除が途中まで進んでいる可能性がある。内容を確認してから再実行する。" >&2
      exit 1
    fi
    aws "${aws_args[@]}" rds delete-db-instance --db-instance-identifier "$old_blue_id" \
      --final-db-snapshot-identifier "$final_snapshot_id" --output json > "$output_dir/delete-db-instance.json"
    echo "Old Blue deletion started: $old_blue_id (final snapshot: $final_snapshot_id)"
    ;;
  *)
    echo "旧 Blue が削除できる状態にない: $old_blue_id (status: $old_blue_status)" >&2
    exit 1
    ;;
esac

# --- Deployment の削除 -----------------------------------------------------
# 旧 Blue の削除を先に行う。逆順にすると、Deployment だけ消えて旧 Blue が残った場合に
# 「切替が完了したか」を確認する手がかりが減るためである（phase 判定で代替はできる）。
if [[ -n "$deployment_id" && "$deployment_status" != DELETING ]]; then
  # [変更] Blue/Green Deployment を削除する。Green（切替後の本番）はそのまま残る。
  aws "${aws_args[@]}" rds delete-blue-green-deployment \
    --blue-green-deployment-identifier "$deployment_id" \
    --output json > "$output_dir/delete-blue-green-deployment.json"
  echo "Deployment deleted: $deployment_id"
fi

echo "Artifacts: $output_dir"
