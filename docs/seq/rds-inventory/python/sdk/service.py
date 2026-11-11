"""RDS の DB インスタンスと DB クラスターの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from aws_client import AwsError
from inventory_common import error_entry, tags_object, utc_iso

TOOL = "rds_inventory.py"
SNAPSHOT_OPTIONS = []


def snapshot(ctx, opts):
    instances = ctx.call("rds", "describe_db_instances", {})["DBInstances"]
    clusters = ctx.call("rds", "describe_db_clusters", {})["DBClusters"]

    # 保留中のメンテナンスが取れないときは、errors に残して続ける
    pending_by_arn, errors = {}, []
    try:
        for p in ctx.call("rds", "describe_pending_maintenance_actions", {})["PendingMaintenanceActions"]:
            pending_by_arn[p["ResourceIdentifier"]] = [
                {
                    "action": d.get("Action"),
                    "description": d.get("Description"),
                    "auto_applied_after": utc_iso(d.get("AutoAppliedAfterDate")),
                    "forced_apply_date": utc_iso(d.get("ForcedApplyDate")),
                    "current_apply_date": utc_iso(d.get("CurrentApplyDate")),
                }
                for d in p.get("PendingMaintenanceActionDetails") or []
            ]
    except AwsError as e:
        errors = [error_entry(e)]

    for i in instances:
        yield instance_record(ctx, i, pending_by_arn.get(i["DBInstanceArn"], []), errors)
    for c in clusters:
        yield cluster_record(ctx, c, pending_by_arn.get(c["DBClusterArn"], []), errors)


def instance_record(ctx, i, pending, errors):
    endpoint = i.get("Endpoint")
    subnet_group = i.get("DBSubnetGroup") or {}
    return ctx.record("rds_db_instance", {
        "db_instance_identifier": i.get("DBInstanceIdentifier"),
        "db_instance_arn": i.get("DBInstanceArn"),
        "engine": i.get("Engine"),
        "engine_version": i.get("EngineVersion"),
        "db_instance_class": i.get("DBInstanceClass"),
        "status": i.get("DBInstanceStatus"),
        "db_cluster_identifier": i.get("DBClusterIdentifier"),
        "multi_az": i.get("MultiAZ"),
        "availability_zone": i.get("AvailabilityZone"),
        "secondary_availability_zone": i.get("SecondaryAvailabilityZone"),
        "storage_type": i.get("StorageType"),
        "allocated_storage_gib": i.get("AllocatedStorage"),
        "iops": i.get("Iops"),
        "storage_encrypted": i.get("StorageEncrypted"),
        "kms_key_id": i.get("KmsKeyId"),
        "publicly_accessible": i.get("PubliclyAccessible"),
        "endpoint": {"address": endpoint.get("Address"), "port": endpoint.get("Port")} if endpoint else None,
        "vpc_id": subnet_group.get("VpcId"),
        "db_subnet_group": subnet_group.get("DBSubnetGroupName"),
        "security_group_ids": [g.get("VpcSecurityGroupId") for g in i.get("VpcSecurityGroups") or []],
        "parameter_groups": [
            {"name": g.get("DBParameterGroupName"), "status": g.get("ParameterApplyStatus")}
            for g in i.get("DBParameterGroups") or []
        ],
        "option_groups": [g.get("OptionGroupName") for g in i.get("OptionGroupMemberships") or []],
        "backup_retention_days": i.get("BackupRetentionPeriod"),
        "preferred_backup_window": i.get("PreferredBackupWindow"),
        "preferred_maintenance_window": i.get("PreferredMaintenanceWindow"),
        "auto_minor_version_upgrade": i.get("AutoMinorVersionUpgrade"),
        "deletion_protection": i.get("DeletionProtection"),
        "ca_certificate_identifier": i.get("CACertificateIdentifier"),
        "performance_insights_enabled": i.get("PerformanceInsightsEnabled"),
        "iam_database_authentication_enabled": i.get("IAMDatabaseAuthenticationEnabled"),
        "monitoring_interval": i.get("MonitoringInterval"),
        "instance_create_time": utc_iso(i.get("InstanceCreateTime")),
        "pending_maintenance": pending,
        "tags": tags_object(i.get("TagList")),
    }, errors)


def cluster_record(ctx, c, pending, errors):
    scaling = c.get("ServerlessV2ScalingConfiguration")
    return ctx.record("rds_db_cluster", {
        "db_cluster_identifier": c.get("DBClusterIdentifier"),
        "db_cluster_arn": c.get("DBClusterArn"),
        "engine": c.get("Engine"),
        "engine_version": c.get("EngineVersion"),
        "engine_mode": c.get("EngineMode"),
        "status": c.get("Status"),
        "members": [
            {"db_instance_identifier": m.get("DBInstanceIdentifier"), "is_writer": m.get("IsClusterWriter")}
            for m in c.get("DBClusterMembers") or []
        ],
        "multi_az": c.get("MultiAZ"),
        "endpoint": c.get("Endpoint"),
        "reader_endpoint": c.get("ReaderEndpoint"),
        "port": c.get("Port"),
        "storage_encrypted": c.get("StorageEncrypted"),
        "kms_key_id": c.get("KmsKeyId"),
        "db_subnet_group": c.get("DBSubnetGroup"),
        "security_group_ids": [g.get("VpcSecurityGroupId") for g in c.get("VpcSecurityGroups") or []],
        "parameter_group": c.get("DBClusterParameterGroup"),
        "backup_retention_days": c.get("BackupRetentionPeriod"),
        "preferred_backup_window": c.get("PreferredBackupWindow"),
        "preferred_maintenance_window": c.get("PreferredMaintenanceWindow"),
        "deletion_protection": c.get("DeletionProtection"),
        "iam_database_authentication_enabled": c.get("IAMDatabaseAuthenticationEnabled"),
        "serverless_v2_scaling": {
            "min_capacity": scaling.get("MinCapacity"),
            "max_capacity": scaling.get("MaxCapacity"),
        } if scaling else None,
        "cluster_create_time": utc_iso(c.get("ClusterCreateTime")),
        "pending_maintenance": pending,
        "tags": tags_object(c.get("TagList")),
    }, errors)


def _parameter_entries(group, parameters):
    return [
        {"parameter_group": group, "name": p.get("ParameterName"), "value": p.get("ParameterValue"),
         "apply_method": p.get("ApplyMethod")}
        for p in parameters
    ]


def parameters(ctx, record):
    """パラメータグループで既定から変えた値（Source=user）。同じパラメータグループは 1 回だけ引く。"""
    if record["record_type"] == "rds_db_instance":
        result = []
        for g in record["parameter_groups"]:
            name = g["name"]
            params = ctx.cached(("pg", name), lambda name=name: ctx.call(
                "rds", "describe_db_parameters", {"DBParameterGroupName": name, "Source": "user"})["Parameters"])
            result += _parameter_entries(name, params)
        return result
    name = record["parameter_group"]
    params = ctx.cached(("cpg", name), lambda: ctx.call(
        "rds", "describe_db_cluster_parameters", {"DBClusterParameterGroupName": name, "Source": "user"})["Parameters"])
    return _parameter_entries(name, params)


DETAIL_KINDS = {
    "parameters": (("rds_db_instance", "rds_db_cluster"), parameters),
}
