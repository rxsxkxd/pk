#!/usr/bin/env bash
# RDS の DB インスタンスと DB クラスターの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=rds-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='parameters:rds_db_instance,rds_db_cluster'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  aws_json rds describe-db-instances >"$work/instances.json"
  aws_json rds describe-db-clusters >"$work/clusters.json"

  # 保留中のメンテナンスが取れないときは、errors に残して続ける
  local pending_error=null
  if ! aws_json rds describe-pending-maintenance-actions >"$work/pending.json" 2>"$work/err"; then
    echo '{"PendingMaintenanceActions": []}' >"$work/pending.json"
    pending_error=$(cli_error DescribePendingMaintenanceActions "$work/err")
  fi

  jq -c -n \
    --argjson common "$common" \
    --argjson pending_error "$pending_error" \
    --slurpfile instances "$work/instances.json" \
    --slurpfile clusters "$work/clusters.json" \
    --slurpfile pending "$work/pending.json" "$jq_lib"'
    ($pending[0].PendingMaintenanceActions
     | map({key: .ResourceIdentifier, value: [.PendingMaintenanceActionDetails[]? | {
         action: .Action,
         description: .Description,
         auto_applied_after: (.AutoAppliedAfterDate | utc_iso),
         forced_apply_date: (.ForcedApplyDate | utc_iso),
         current_apply_date: (.CurrentApplyDate | utc_iso)
       }]})
     | from_entries) as $pending_by_arn
    | [$pending_error | select(. != null)] as $errors
    | (
        $instances[0].DBInstances[]
        | record("rds_db_instance"; {
            db_instance_identifier: .DBInstanceIdentifier,
            db_instance_arn: .DBInstanceArn,
            engine: .Engine,
            engine_version: .EngineVersion,
            db_instance_class: .DBInstanceClass,
            status: .DBInstanceStatus,
            db_cluster_identifier: .DBClusterIdentifier,
            multi_az: .MultiAZ,
            availability_zone: .AvailabilityZone,
            secondary_availability_zone: .SecondaryAvailabilityZone,
            storage_type: .StorageType,
            allocated_storage_gib: .AllocatedStorage,
            iops: .Iops,
            storage_encrypted: .StorageEncrypted,
            kms_key_id: .KmsKeyId,
            publicly_accessible: .PubliclyAccessible,
            endpoint: (if .Endpoint == null then null else {address: .Endpoint.Address, port: .Endpoint.Port} end),
            vpc_id: .DBSubnetGroup.VpcId,
            db_subnet_group: .DBSubnetGroup.DBSubnetGroupName,
            security_group_ids: [.VpcSecurityGroups[]?.VpcSecurityGroupId],
            parameter_groups: [.DBParameterGroups[]? | {name: .DBParameterGroupName, status: .ParameterApplyStatus}],
            option_groups: [.OptionGroupMemberships[]?.OptionGroupName],
            backup_retention_days: .BackupRetentionPeriod,
            preferred_backup_window: .PreferredBackupWindow,
            preferred_maintenance_window: .PreferredMaintenanceWindow,
            auto_minor_version_upgrade: .AutoMinorVersionUpgrade,
            deletion_protection: .DeletionProtection,
            ca_certificate_identifier: .CACertificateIdentifier,
            performance_insights_enabled: .PerformanceInsightsEnabled,
            iam_database_authentication_enabled: .IAMDatabaseAuthenticationEnabled,
            monitoring_interval: .MonitoringInterval,
            instance_create_time: (.InstanceCreateTime | utc_iso),
            pending_maintenance: ($pending_by_arn[.DBInstanceArn] // []),
            tags: (.TagList | tags_object)
          }; $errors)
      ),
      (
        $clusters[0].DBClusters[]
        | record("rds_db_cluster"; {
            db_cluster_identifier: .DBClusterIdentifier,
            db_cluster_arn: .DBClusterArn,
            engine: .Engine,
            engine_version: .EngineVersion,
            engine_mode: .EngineMode,
            status: .Status,
            members: [.DBClusterMembers[]? | {db_instance_identifier: .DBInstanceIdentifier, is_writer: .IsClusterWriter}],
            multi_az: .MultiAZ,
            endpoint: .Endpoint,
            reader_endpoint: .ReaderEndpoint,
            port: .Port,
            storage_encrypted: .StorageEncrypted,
            kms_key_id: .KmsKeyId,
            db_subnet_group: .DBSubnetGroup,
            security_group_ids: [.VpcSecurityGroups[]?.VpcSecurityGroupId],
            parameter_group: .DBClusterParameterGroup,
            backup_retention_days: .BackupRetentionPeriod,
            preferred_backup_window: .PreferredBackupWindow,
            preferred_maintenance_window: .PreferredMaintenanceWindow,
            deletion_protection: .DeletionProtection,
            iam_database_authentication_enabled: .IAMDatabaseAuthenticationEnabled,
            serverless_v2_scaling: (
              .ServerlessV2ScalingConfiguration
              | if . == null then null else {min_capacity: .MinCapacity, max_capacity: .MaxCapacity} end
            ),
            cluster_create_time: (.ClusterCreateTime | utc_iso),
            pending_maintenance: ($pending_by_arn[.DBClusterArn] // []),
            tags: (.TagList | tags_object)
          }; $errors)
      )'
}

instance_parameters() { aws_paced rds describe-db-parameters --db-parameter-group-name "$1" --source user; }
cluster_parameters() { aws_paced rds describe-db-cluster-parameters --db-cluster-parameter-group-name "$1" --source user; }

# パラメータグループで既定から変えた値（Source=user）。同じパラメータグループは 1 回だけ引く
detail_parameters() {
  local type group
  type=$(jq -r '.record_type' <<<"$1")
  if [ "$type" = rds_db_instance ]; then
    for group in $(jq -r '.parameter_groups[].name' <<<"$1"); do
      cached "pg-$group" instance_parameters "$group" |
        jq -c --arg g "$group" '.Parameters[] | {parameter_group: $g, name: .ParameterName, value: .ParameterValue, apply_method: .ApplyMethod}' || exit 1
    done | jq -s -c .
  else
    group=$(jq -r '.parameter_group' <<<"$1")
    cached "cpg-$group" cluster_parameters "$group" |
      jq -c --arg g "$group" '[.Parameters[] | {parameter_group: $g, name: .ParameterName, value: .ParameterValue, apply_method: .ApplyMethod}]'
  fi
}

run_main "$@"
