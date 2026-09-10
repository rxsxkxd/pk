#!/usr/bin/env python3
"""RDS インベントリと移行カタログから Blue/Green 実行設定を生成する。"""

import argparse
import os
import re
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError as error:
    raise SystemExit(
        "PyYAML is required. Install it with: python3 -m pip install 'PyYAML==6.0.2'"
    ) from error


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate config/blue-green YAML from a catalog and RDS inventory."
    )
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def read_yaml(path):
    try:
        with path.open(encoding="utf-8") as handle:
            value = yaml.safe_load(handle)
    except OSError as error:
        raise SystemExit(f"cannot read catalog {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"catalog must be a YAML mapping: {path}")
    return value


def read_inventory(path):
    try:
        import json

        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError) as error:
        raise SystemExit(f"cannot read RDS inventory {path}: {error}") from error
    instances = value.get("DBInstances") if isinstance(value, dict) else None
    if not isinstance(instances, list):
        raise SystemExit(f"RDS inventory has no DBInstances array: {path}")
    region = value.get("aws_region") if isinstance(value, dict) else None
    if not isinstance(region, str) or not region.strip():
        raise SystemExit(
            f"RDS inventory has no aws_region: {path}; collect it with collect_rds_instance_inventory.sh"
        )

    indexed = {}
    for instance in instances:
        if not isinstance(instance, dict):
            continue
        identifier = instance.get("DBInstanceIdentifier")
        if identifier:
            if identifier in indexed:
                raise SystemExit(f"RDS inventory contains duplicate DB instance: {identifier}")
            indexed[identifier] = instance
    return indexed, region


def required(mapping, key, context):
    value = mapping.get(key) if isinstance(mapping, dict) else None
    if value is None or str(value).strip() == "":
        raise SystemExit(f"{context}: {key} is required")
    return value


def source_parameter_group(instance, context):
    groups = instance.get("DBParameterGroups")
    if not isinstance(groups, list) or len(groups) != 1:
        raise SystemExit(f"{context}: RDS inventory must contain exactly one DBParameterGroups entry")
    name = groups[0].get("DBParameterGroupName") if isinstance(groups[0], dict) else None
    if not name:
        raise SystemExit(f"{context}: DBParameterGroups[0].DBParameterGroupName is required")
    return name


def normalize_major_minor(version, context):
    match = re.match(r"^(\d+)\.(\d+)", str(version))
    if not match:
        raise SystemExit(f"{context}: invalid RDS EngineVersion: {version!r}")
    return f"{match.group(1)}.{match.group(2)}"


# 移行先の共通ターゲット。カタログで engine_version を省略した接続はこの値へ上げる。
# RDS で利用可能なバージョンかは describe-db-engine-versions で確認する。
DEFAULT_TARGET_ENGINE_VERSION = "8.4.11"

MYSQL_AUTH_METHODS = ("secrets_manager", "parameter_store", "plaintext", "prompt")
MYSQL_AUTH_UNIMPLEMENTED = ("iam",)
MYSQL_VERIFICATION_KEYS = {
    "enabled", "user", "auth_method", "secret_id",
    "parameter_name", "user_parameter_name", "ssl_ca", "port",
}
TARGET_KEYS = {"db_parameter_group_name", "engine_version", "db_instance_class"}
BINDING_KEYS = {"rds_instance", "schema_name", "connect_via", "target", "mysql_verification"}


def mysql_verification(binding, context, environment_name):
    """接続の mysql_verification を検証して、生成する設定へ渡す。

    Step 4 の実効値収集と Step 7 の逆レプリケーション確認で使う接続設定である。
    カタログには参照（secret_id / parameter_name）だけを置き、パスワードそのものは
    置かない。auth_method: plaintext を使う場合は、生成後の設定ファイルへ手で書く。
    """
    given = binding.get("mysql_verification") or {}
    if not isinstance(given, dict):
        raise SystemExit(f"{context}.mysql_verification must be a mapping")

    unknown = set(given) - MYSQL_VERIFICATION_KEYS
    if unknown:
        raise SystemExit(
            f"{context}.mysql_verification has unknown keys: {', '.join(sorted(unknown))}"
        )
    if "password" in given:
        raise SystemExit(
            f"{context}.mysql_verification.password はカタログへ書かない。"
            "auth_method: plaintext は生成後の設定ファイルへ手で記載する"
        )

    auth = str(given.get("auth_method") or "prompt")
    if auth in MYSQL_AUTH_UNIMPLEMENTED:
        raise SystemExit(f"{context}.mysql_verification.auth_method: {auth} は未実装である")
    if auth not in MYSQL_AUTH_METHODS:
        raise SystemExit(
            f"{context}.mysql_verification.auth_method が不正: {auth}"
            f"（有効な値: {', '.join(MYSQL_AUTH_METHODS)}）"
        )
    if auth == "plaintext" and environment_name == "production":
        raise SystemExit(
            f"{context}.mysql_verification.auth_method: plaintext は production では使用できない"
        )

    return {
        "enabled": bool(given.get("enabled", False)),
        "user": given.get("user") or "",
        "auth_method": auth,
        "secret_id": given.get("secret_id") or "",
        "parameter_name": given.get("parameter_name") or "",
        "user_parameter_name": given.get("user_parameter_name") or "",
        "ssl_ca": given.get("ssl_ca") or "",
        "port": int(given.get("port") or 3306),
    }


def resolve_target(target, instance, context):
    """target を解決する。db_parameter_group_name 以外は省略できる。

    engine_version を省略した場合は共通ターゲット（DEFAULT_TARGET_ENGINE_VERSION）へ上げる。
    db_instance_class を省略した場合は Blue の実値を踏襲する。
    """
    if not isinstance(target, dict):
        raise SystemExit(f"{context}.target must be a mapping")
    unknown = set(target) - TARGET_KEYS
    if unknown:
        raise SystemExit(f"{context}.target has unknown keys: {', '.join(sorted(unknown))}")

    parameter_group = required(target, "db_parameter_group_name", f"{context}.target")

    # 省略時は共通ターゲットへ上げる。Blue の値を踏襲しない（それでは移行にならない）。
    engine_version = target.get("engine_version") or DEFAULT_TARGET_ENGINE_VERSION

    # インスタンスクラスは省略時に Blue の実値を踏襲する。
    instance_class = target.get("db_instance_class")
    if not instance_class:
        instance_class = required(instance, "DBInstanceClass", context)

    return {
        "target_engine_version": str(engine_version),
        "target_db_instance_class": str(instance_class),
        "target_db_parameter_group_name": str(parameter_group),
    }


def generate(catalog, inventory, inventory_region, environment_name):
    """カタログの接続定義から、指定環境の Blue/Green 設定を生成する。

    生成単位は RDS DB インスタンスである。同じ rds_instance を指す接続は
    1 つの Blue/Green deployment にまとめる。
    """
    applications = catalog.get("applications")
    if not isinstance(applications, dict) or not applications:
        raise SystemExit("catalog.applications must be a non-empty mapping")

    known_environments = catalog.get("database_environments")
    if not isinstance(known_environments, list) or not known_environments:
        raise SystemExit("catalog.database_environments must be a non-empty list")
    if environment_name not in known_environments:
        raise SystemExit(
            f"unknown environment: {environment_name}"
            f"（catalog.database_environments: {', '.join(map(str, known_environments))}）"
        )

    parameter_groups = catalog.get("parameter_groups")
    if not isinstance(parameter_groups, dict) or not parameter_groups:
        raise SystemExit("catalog.parameter_groups must be a non-empty mapping")

    services = {}
    for application_name, application in sorted(applications.items()):
        application_context = f"applications.{application_name}"
        if not isinstance(application, dict):
            raise SystemExit(f"{application_context} must be a mapping")
        connections = required(application, "connections", application_context)
        if not isinstance(connections, dict):
            raise SystemExit(f"{application_context}.connections must be a mapping")

        for connection_name, connection in sorted(connections.items()):
            connection_context = f"{application_context}.connections.{connection_name}"
            if not isinstance(connection, dict):
                raise SystemExit(f"{connection_context} must be a mapping")
            environments = connection.get("environments") or {}
            if not isinstance(environments, dict):
                raise SystemExit(f"{connection_context}.environments must be a mapping")

            for name in environments:
                if name not in known_environments:
                    raise SystemExit(
                        f"{connection_context}.environments.{name}: "
                        "catalog.database_environments に無い環境である"
                    )

            binding = environments.get(environment_name)
            if binding is None:
                continue
            context = f"{connection_context}.environments.{environment_name}"
            if not isinstance(binding, dict):
                raise SystemExit(f"{context} must be a mapping")
            unknown = set(binding) - BINDING_KEYS
            if unknown:
                raise SystemExit(f"{context} has unknown keys: {', '.join(sorted(unknown))}")

            source_id = str(required(binding, "rds_instance", context))
            schema_name = str(required(binding, "schema_name", context))

            instance = inventory.get(source_id)
            if instance is None:
                raise SystemExit(f"{context}: source DB instance is absent from inventory: {source_id}")
            if instance.get("Engine") != "mysql":
                raise SystemExit(
                    f"{context}: source DB instance Engine must be mysql,"
                    f" got {instance.get('Engine')!r}"
                )

            target = resolve_target(binding.get("target"), instance, context)
            group_name = target["target_db_parameter_group_name"]
            group = parameter_groups.get(group_name)
            if not isinstance(group, dict):
                raise SystemExit(f"{context}: catalog.parameter_groups に無い: {group_name}")
            template_path = required(group, "template_path", f"parameter_groups.{group_name}")

            service = {
                "source_db_instance_identifier": source_id,
                "source_engine_version": normalize_major_minor(
                    required(instance, "EngineVersion", context), context
                ),
                "source_db_parameter_group_name": source_parameter_group(instance, context),
                **target,
                "target_parameter_group_template_path": str(template_path),
                "protection_snapshot_identifier": f"{source_id}-pre-bg",
                "final_snapshot_identifier": f"{source_id}-final",
                # 影響範囲。切替前のレビューで使う。
                "schemas": [schema_name],
                "connected_by": [f"{application_name}.{connection_name}"],
                "mysql_verification": mysql_verification(binding, context, environment_name),
                "actions": {
                    "build": "pending",
                    "switchover": "pending",
                    "switchover_timeout": 300,
                    "cleanup": "pending",
                },
            }

            existing = services.get(source_id)
            if existing is None:
                services[source_id] = service
                continue

            # 同じインスタンスを指す接続は 1 つの deployment にまとめる。
            # 重複して書かれた設定は一致していなければならない。
            for key in ("target_engine_version", "target_db_instance_class",
                        "target_db_parameter_group_name", "mysql_verification"):
                if existing[key] != service[key]:
                    raise SystemExit(
                        f"{context}: {source_id} を指す他の接続と {key} が食い違う"
                        f"（{existing[key]!r} と {service[key]!r}）"
                    )
            if schema_name not in existing["schemas"]:
                existing["schemas"].append(schema_name)
                existing["schemas"].sort()
            connected = f"{application_name}.{connection_name}"
            if connected not in existing["connected_by"]:
                existing["connected_by"].append(connected)
                existing["connected_by"].sort()

    if not services:
        raise SystemExit(f"no connection is defined for the environment: {environment_name}")

    return {
        "environment": environment_name,
        "aws_region": inventory_region,
        "services": services,
    }


def write_yaml(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as handle:
        yaml.safe_dump(value, handle, allow_unicode=True, sort_keys=False, default_flow_style=False)
        temporary_path = Path(handle.name)
    os.replace(temporary_path, path)


def main():
    args = parse_args()
    catalog = read_yaml(args.catalog)
    inventory, inventory_region = read_inventory(args.inventory)
    generated = generate(catalog, inventory, inventory_region, args.environment)
    write_yaml(args.output, generated)
    print(f"Generated Blue/Green config: {args.output}")


if __name__ == "__main__":
    main()
