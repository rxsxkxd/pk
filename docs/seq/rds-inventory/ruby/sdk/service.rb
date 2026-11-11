# frozen_string_literal: true

# RDS の DB インスタンスと DB クラスターの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-rds"

module Service
  TOOL = "rds_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def snapshot(ctx, _opts)
    rds = ctx.client(:RDS)
    instances = rds.describe_db_instances.flat_map(&:db_instances)
    clusters = rds.describe_db_clusters.flat_map(&:db_clusters)

    # 保留中のメンテナンスが取れないときは、errors に残して続ける
    pending_by_arn = {}
    errors = []
    begin
      rds.describe_pending_maintenance_actions.flat_map(&:pending_maintenance_actions).each do |p|
        pending_by_arn[p.resource_identifier] = (p.pending_maintenance_action_details || []).map do |d|
          {
            "action" => d.action,
            "description" => d.description,
            "auto_applied_after" => InventoryCommon.utc_iso(d.auto_applied_after_date),
            "forced_apply_date" => InventoryCommon.utc_iso(d.forced_apply_date),
            "current_apply_date" => InventoryCommon.utc_iso(d.current_apply_date),
          }
        end
      end
    rescue Aws::Errors::ServiceError => e
      errors = [InventoryCommon.error_entry(e)]
    end

    instances.map { |i| instance_record(ctx, i, pending_by_arn.fetch(i.db_instance_arn, []), errors) } +
      clusters.map { |c| cluster_record(ctx, c, pending_by_arn.fetch(c.db_cluster_arn, []), errors) }
  end

  def instance_record(ctx, i, pending, errors)
    endpoint = i.endpoint
    ctx.record("rds_db_instance", {
      "db_instance_identifier" => i.db_instance_identifier,
      "db_instance_arn" => i.db_instance_arn,
      "engine" => i.engine,
      "engine_version" => i.engine_version,
      "db_instance_class" => i.db_instance_class,
      "status" => i.db_instance_status,
      "db_cluster_identifier" => i.db_cluster_identifier,
      "multi_az" => i.multi_az,
      "availability_zone" => i.availability_zone,
      "secondary_availability_zone" => i.secondary_availability_zone,
      "storage_type" => i.storage_type,
      "allocated_storage_gib" => i.allocated_storage,
      "iops" => i.iops,
      "storage_encrypted" => i.storage_encrypted,
      "kms_key_id" => i.kms_key_id,
      "publicly_accessible" => i.publicly_accessible,
      "endpoint" => endpoint && { "address" => endpoint.address, "port" => endpoint.port },
      "vpc_id" => i.db_subnet_group&.vpc_id,
      "db_subnet_group" => i.db_subnet_group&.db_subnet_group_name,
      "security_group_ids" => (i.vpc_security_groups || []).map(&:vpc_security_group_id),
      "parameter_groups" => (i.db_parameter_groups || []).map do |g|
        { "name" => g.db_parameter_group_name, "status" => g.parameter_apply_status }
      end,
      "option_groups" => (i.option_group_memberships || []).map(&:option_group_name),
      "backup_retention_days" => i.backup_retention_period,
      "preferred_backup_window" => i.preferred_backup_window,
      "preferred_maintenance_window" => i.preferred_maintenance_window,
      "auto_minor_version_upgrade" => i.auto_minor_version_upgrade,
      "deletion_protection" => i.deletion_protection,
      "ca_certificate_identifier" => i.ca_certificate_identifier,
      "performance_insights_enabled" => i.performance_insights_enabled,
      "iam_database_authentication_enabled" => i.iam_database_authentication_enabled,
      "monitoring_interval" => i.monitoring_interval,
      "instance_create_time" => InventoryCommon.utc_iso(i.instance_create_time),
      "pending_maintenance" => pending,
      "tags" => InventoryCommon.tags_object(i.tag_list),
    }, errors)
  end

  def cluster_record(ctx, c, pending, errors)
    scaling = c.serverless_v2_scaling_configuration
    ctx.record("rds_db_cluster", {
      "db_cluster_identifier" => c.db_cluster_identifier,
      "db_cluster_arn" => c.db_cluster_arn,
      "engine" => c.engine,
      "engine_version" => c.engine_version,
      "engine_mode" => c.engine_mode,
      "status" => c.status,
      "members" => (c.db_cluster_members || []).map do |m|
        { "db_instance_identifier" => m.db_instance_identifier, "is_writer" => m.is_cluster_writer }
      end,
      "multi_az" => c.multi_az,
      "endpoint" => c.endpoint,
      "reader_endpoint" => c.reader_endpoint,
      "port" => c.port,
      "storage_encrypted" => c.storage_encrypted,
      "kms_key_id" => c.kms_key_id,
      "db_subnet_group" => c.db_subnet_group,
      "security_group_ids" => (c.vpc_security_groups || []).map(&:vpc_security_group_id),
      "parameter_group" => c.db_cluster_parameter_group,
      "backup_retention_days" => c.backup_retention_period,
      "preferred_backup_window" => c.preferred_backup_window,
      "preferred_maintenance_window" => c.preferred_maintenance_window,
      "deletion_protection" => c.deletion_protection,
      "iam_database_authentication_enabled" => c.iam_database_authentication_enabled,
      "serverless_v2_scaling" => scaling && { "min_capacity" => scaling.min_capacity, "max_capacity" => scaling.max_capacity },
      "cluster_create_time" => InventoryCommon.utc_iso(c.cluster_create_time),
      "pending_maintenance" => pending,
      "tags" => InventoryCommon.tags_object(c.tag_list),
    }, errors)
  end

  def parameter_entries(group, parameters)
    parameters.map do |p|
      { "parameter_group" => group, "name" => p.parameter_name, "value" => p.parameter_value,
        "apply_method" => p.apply_method }
    end
  end

  # パラメータグループで既定から変えた値（Source=user）。同じパラメータグループは 1 回だけ引く
  def parameters(ctx, record)
    rds = ctx.client(:RDS)
    if record["record_type"] == "rds_db_instance"
      record["parameter_groups"].flat_map do |g|
        name = g["name"]
        params = ctx.cached([:pg, name]) do
          ctx.pace { rds.describe_db_parameters(db_parameter_group_name: name, source: "user").flat_map(&:parameters) }
        end
        parameter_entries(name, params)
      end
    else
      name = record["parameter_group"]
      params = ctx.cached([:cpg, name]) do
        ctx.pace do
          rds.describe_db_cluster_parameters(db_cluster_parameter_group_name: name, source: "user").flat_map(&:parameters)
        end
      end
      parameter_entries(name, params)
    end
  end

  DETAIL_KINDS = {
    "parameters" => [%w[rds_db_instance rds_db_cluster], :parameters],
  }.freeze
end
