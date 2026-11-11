# frozen_string_literal: true

# RDS の DB インスタンスと DB クラスターの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "rds_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def snapshot(ctx, _opts)
    instances = ctx.call("rds", "describe_db_instances")["DBInstances"]
    clusters = ctx.call("rds", "describe_db_clusters")["DBClusters"]

    # 保留中のメンテナンスが取れないときは、errors に残して続ける
    pending_by_arn = {}
    errors = []
    begin
      ctx.call("rds", "describe_pending_maintenance_actions")["PendingMaintenanceActions"].each do |p|
        pending_by_arn[p["ResourceIdentifier"]] = (p["PendingMaintenanceActionDetails"] || []).map do |d|
          {
            "action" => d["Action"],
            "description" => d["Description"],
            "auto_applied_after" => InventoryCommon.utc_iso(d["AutoAppliedAfterDate"]),
            "forced_apply_date" => InventoryCommon.utc_iso(d["ForcedApplyDate"]),
            "current_apply_date" => InventoryCommon.utc_iso(d["CurrentApplyDate"]),
          }
        end
      end
    rescue InventoryCommon::AwsError => e
      errors = [InventoryCommon.error_entry(e)]
    end

    instances.map { |i| instance_record(ctx, i, pending_by_arn.fetch(i["DBInstanceArn"], []), errors) } +
      clusters.map { |c| cluster_record(ctx, c, pending_by_arn.fetch(c["DBClusterArn"], []), errors) }
  end

  def instance_record(ctx, i, pending, errors)
    endpoint = i["Endpoint"]
    ctx.record("rds_db_instance", {
      "db_instance_identifier" => i["DBInstanceIdentifier"],
      "db_instance_arn" => i["DBInstanceArn"],
      "engine" => i["Engine"],
      "engine_version" => i["EngineVersion"],
      "db_instance_class" => i["DBInstanceClass"],
      "status" => i["DBInstanceStatus"],
      "db_cluster_identifier" => i["DBClusterIdentifier"],
      "multi_az" => i["MultiAZ"],
      "availability_zone" => i["AvailabilityZone"],
      "secondary_availability_zone" => i["SecondaryAvailabilityZone"],
      "storage_type" => i["StorageType"],
      "allocated_storage_gib" => i["AllocatedStorage"],
      "iops" => i["Iops"],
      "storage_encrypted" => i["StorageEncrypted"],
      "kms_key_id" => i["KmsKeyId"],
      "publicly_accessible" => i["PubliclyAccessible"],
      "endpoint" => endpoint && { "address" => endpoint["Address"], "port" => endpoint["Port"] },
      "vpc_id" => i.dig("DBSubnetGroup", "VpcId"),
      "db_subnet_group" => i.dig("DBSubnetGroup", "DBSubnetGroupName"),
      "security_group_ids" => (i["VpcSecurityGroups"] || []).map { |g| g["VpcSecurityGroupId"] },
      "parameter_groups" => (i["DBParameterGroups"] || []).map do |g|
        { "name" => g["DBParameterGroupName"], "status" => g["ParameterApplyStatus"] }
      end,
      "option_groups" => (i["OptionGroupMemberships"] || []).map { |g| g["OptionGroupName"] },
      "backup_retention_days" => i["BackupRetentionPeriod"],
      "preferred_backup_window" => i["PreferredBackupWindow"],
      "preferred_maintenance_window" => i["PreferredMaintenanceWindow"],
      "auto_minor_version_upgrade" => i["AutoMinorVersionUpgrade"],
      "deletion_protection" => i["DeletionProtection"],
      "ca_certificate_identifier" => i["CACertificateIdentifier"],
      "performance_insights_enabled" => i["PerformanceInsightsEnabled"],
      "iam_database_authentication_enabled" => i["IAMDatabaseAuthenticationEnabled"],
      "monitoring_interval" => i["MonitoringInterval"],
      "instance_create_time" => InventoryCommon.utc_iso(i["InstanceCreateTime"]),
      "pending_maintenance" => pending,
      "tags" => InventoryCommon.tags_object(i["TagList"]),
    }, errors)
  end

  def cluster_record(ctx, c, pending, errors)
    scaling = c["ServerlessV2ScalingConfiguration"]
    ctx.record("rds_db_cluster", {
      "db_cluster_identifier" => c["DBClusterIdentifier"],
      "db_cluster_arn" => c["DBClusterArn"],
      "engine" => c["Engine"],
      "engine_version" => c["EngineVersion"],
      "engine_mode" => c["EngineMode"],
      "status" => c["Status"],
      "members" => (c["DBClusterMembers"] || []).map do |m|
        { "db_instance_identifier" => m["DBInstanceIdentifier"], "is_writer" => m["IsClusterWriter"] }
      end,
      "multi_az" => c["MultiAZ"],
      "endpoint" => c["Endpoint"],
      "reader_endpoint" => c["ReaderEndpoint"],
      "port" => c["Port"],
      "storage_encrypted" => c["StorageEncrypted"],
      "kms_key_id" => c["KmsKeyId"],
      "db_subnet_group" => c["DBSubnetGroup"],
      "security_group_ids" => (c["VpcSecurityGroups"] || []).map { |g| g["VpcSecurityGroupId"] },
      "parameter_group" => c["DBClusterParameterGroup"],
      "backup_retention_days" => c["BackupRetentionPeriod"],
      "preferred_backup_window" => c["PreferredBackupWindow"],
      "preferred_maintenance_window" => c["PreferredMaintenanceWindow"],
      "deletion_protection" => c["DeletionProtection"],
      "iam_database_authentication_enabled" => c["IAMDatabaseAuthenticationEnabled"],
      "serverless_v2_scaling" => scaling && { "min_capacity" => scaling["MinCapacity"], "max_capacity" => scaling["MaxCapacity"] },
      "cluster_create_time" => InventoryCommon.utc_iso(c["ClusterCreateTime"]),
      "pending_maintenance" => pending,
      "tags" => InventoryCommon.tags_object(c["TagList"]),
    }, errors)
  end

  def parameter_entries(group, parameters)
    parameters.map do |p|
      { "parameter_group" => group, "name" => p["ParameterName"], "value" => p["ParameterValue"],
        "apply_method" => p["ApplyMethod"] }
    end
  end

  # パラメータグループで既定から変えた値（Source=user）。同じパラメータグループは 1 回だけ引く
  def parameters(ctx, record)
    if record["record_type"] == "rds_db_instance"
      record["parameter_groups"].flat_map do |g|
        name = g["name"]
        params = ctx.cached([:pg, name]) do
          ctx.call("rds", "describe_db_parameters", { "DBParameterGroupName" => name, "Source" => "user" })["Parameters"]
        end
        parameter_entries(name, params)
      end
    else
      name = record["parameter_group"]
      params = ctx.cached([:cpg, name]) do
        ctx.call("rds", "describe_db_cluster_parameters",
                 { "DBClusterParameterGroupName" => name, "Source" => "user" })["Parameters"]
      end
      parameter_entries(name, params)
    end
  end

  DETAIL_KINDS = {
    "parameters" => [%w[rds_db_instance rds_db_cluster], :parameters],
  }.freeze
end
