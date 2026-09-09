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

    indexed = {}
    for instance in instances:
        if not isinstance(instance, dict):
            continue
        identifier = instance.get("DBInstanceIdentifier")
        if identifier:
            if identifier in indexed:
                raise SystemExit(f"RDS inventory contains duplicate DB instance: {identifier}")
            indexed[identifier] = instance
    return indexed


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


def generate(catalog, inventory, environment_name):
    environments = catalog.get("environments")
    if not isinstance(environments, dict) or environment_name not in environments:
        raise SystemExit(f"environment is not defined in catalog: {environment_name}")
    environment = environments[environment_name]
    if not isinstance(environment, dict):
        raise SystemExit(f"environment must be a mapping: {environment_name}")

    region = required(environment, "aws_region", f"environments.{environment_name}")
    units = required(environment, "migration_units", f"environments.{environment_name}")
    if not isinstance(units, dict) or not units:
        raise SystemExit(f"environments.{environment_name}.migration_units must be a non-empty mapping")

    services = {}
    source_ids = set()
    for unit_name, unit in units.items():
        context = f"environments.{environment_name}.migration_units.{unit_name}"
        if not isinstance(unit, dict):
            raise SystemExit(f"{context} must be a mapping")
        source_id = str(required(unit, "source_db_instance_identifier", context))
        if source_id in source_ids:
            raise SystemExit(f"{context}: duplicate source_db_instance_identifier: {source_id}")
        source_ids.add(source_id)

        instance = inventory.get(source_id)
        if instance is None:
            raise SystemExit(f"{context}: source DB instance is absent from inventory: {source_id}")
        if instance.get("Engine") != "mysql":
            raise SystemExit(f"{context}: source DB instance Engine must be mysql, got {instance.get('Engine')!r}")

        target = required(unit, "target", context)
        if not isinstance(target, dict):
            raise SystemExit(f"{context}.target must be a mapping")
        target_context = f"{context}.target"
        services[unit_name] = {
            "source_db_instance_identifier": source_id,
            "source_engine_version": normalize_major_minor(
                required(instance, "EngineVersion", context), context
            ),
            "source_db_parameter_group_name": source_parameter_group(instance, context),
            "target_engine_version": required(target, "engine_version", target_context),
            "target_db_instance_class": required(target, "db_instance_class", target_context),
            "target_db_parameter_group_name": required(
                target, "db_parameter_group_name", target_context
            ),
            "target_parameter_group_template_path": required(
                target, "parameter_group_template_path", target_context
            ),
            "protection_snapshot_identifier": f"{source_id}-pre-bg",
            "final_snapshot_identifier": f"{source_id}-final",
            "actions": {
                "build": "pending",
                "switchover": "pending",
                "switchover_timeout": 300,
                "cleanup": "pending",
            },
        }

    return {
        "environment": environment_name,
        "aws_region": region,
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
    inventory = read_inventory(args.inventory)
    generated = generate(catalog, inventory, args.environment)
    write_yaml(args.output, generated)
    print(f"Generated Blue/Green config: {args.output}")


if __name__ == "__main__":
    main()
