#!/usr/bin/env python3
"""Lambda 関数ごとに 設定 / ベース OS / トリガー を JSONL で出力する。

API 呼び出しは ListFunctions と ListEventSourceMappings をリージョン全体で 1 回ずつ（ページ分）と、
関数ごとの GetPolicy だけ。出力の項目は ../README.md を参照。
"""

import json
import os
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

RUNTIMES_PATH = Path(__file__).resolve().parent.parent / "runtimes.json"


def run(client, out, runtimes):
    functions = paginate(client, "list_functions", "Functions")
    mappings = paginate(client, "list_event_source_mappings", "EventSourceMappings")

    for fn in functions:
        policy, error = fetch_policy(client, fn["FunctionName"])
        own_mappings = [m for m in mappings if unqualified(m["FunctionArn"]) == fn["FunctionArn"]]
        rec = record(fn, own_mappings, policy, error, runtimes)
        out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")


def paginate(client, operation, key):
    return [item for page in client.get_paginator(operation).paginate() for item in page[key]]


def fetch_policy(client, name):
    """ポリシーが無いだけ（ResourceNotFoundException）はエラーにしない。"""
    try:
        return json.loads(client.get_policy(FunctionName=name)["Policy"]), None
    except ClientError as e:
        err = e.response["Error"]
        if err["Code"] == "ResourceNotFoundException":
            return None, None
        return None, {"operation": "GetPolicy", "code": err["Code"], "message": err.get("Message")}


def record(fn, mappings, policy, error, runtimes):
    vpc = fn.get("VpcConfig") or {}
    logging = fn.get("LoggingConfig") or {}
    statements = (policy or {}).get("Statement") or []
    return {
        "function_name": fn["FunctionName"],
        "function_arn": fn["FunctionArn"],
        "description": fn.get("Description"),
        "package_type": fn.get("PackageType") or "Zip",
        "runtime": fn.get("Runtime"),
        "handler": fn.get("Handler"),
        "architecture": (fn.get("Architectures") or ["x86_64"])[0],
        "base_os": base_os(fn, runtimes),
        "memory_mb": fn.get("MemorySize"),
        "timeout_sec": fn.get("Timeout"),
        "ephemeral_storage_mb": (fn.get("EphemeralStorage") or {}).get("Size"),
        "code_size_bytes": fn.get("CodeSize"),
        "last_modified": fn.get("LastModified"),
        "role": fn.get("Role"),
        "vpc": {
            "vpc_id": vpc["VpcId"],
            "subnet_ids": vpc.get("SubnetIds") or [],
            "security_group_ids": vpc.get("SecurityGroupIds") or [],
        } if vpc.get("VpcId") else None,
        "layers": [layer["Arn"] for layer in fn.get("Layers") or []],
        "environment_variable_keys": sorted(((fn.get("Environment") or {}).get("Variables") or {}).keys()),
        "tracing_mode": (fn.get("TracingConfig") or {}).get("Mode"),
        "log_group": logging.get("LogGroup"),
        "log_format": logging.get("LogFormat"),
        "dead_letter_target_arn": (fn.get("DeadLetterConfig") or {}).get("TargetArn"),
        "kms_key_arn": fn.get("KMSKeyArn"),
        "snap_start": (fn.get("SnapStart") or {}).get("ApplyOn"),
        "triggers": [policy_trigger(st) for st in statements] + [mapping_trigger(m) for m in mappings],
        "errors": [error] if error else [],
    }


def base_os(fn, runtimes):
    if fn.get("PackageType") == "Image":
        return "Container Image"
    return runtimes.get(fn.get("Runtime") or "", "Unknown")


def policy_trigger(statement):
    principal = statement.get("Principal")
    if isinstance(principal, dict):
        principal = principal.get("Service") or principal.get("AWS")
    condition = statement.get("Condition") or {}
    return {
        "type": "resource_policy",
        "sid": statement.get("Sid"),
        "effect": statement.get("Effect"),
        "principal": principal,
        "action": statement.get("Action"),
        "source_arn": (condition.get("ArnLike") or {}).get("AWS:SourceArn")
        or (condition.get("ArnEquals") or {}).get("AWS:SourceArn"),
        "source_account": (condition.get("StringEquals") or {}).get("AWS:SourceAccount"),
        "function_url_auth_type": (condition.get("StringEquals") or {}).get("lambda:FunctionUrlAuthType"),
    }


def mapping_trigger(mapping):
    endpoints = (mapping.get("SelfManagedEventSource") or {}).get("Endpoints") or {}
    return {
        "type": "event_source_mapping",
        "uuid": mapping.get("UUID"),
        "event_source": mapping.get("EventSourceArn"),
        "self_managed_endpoints": endpoints.get("KAFKA_BOOTSTRAP_SERVERS"),
        "topics": mapping.get("Topics") or [],
        "qualifier": qualifier(mapping["FunctionArn"]),
        "state": mapping.get("State"),
        "batch_size": mapping.get("BatchSize"),
        "maximum_batching_window_sec": mapping.get("MaximumBatchingWindowInSeconds"),
        "starting_position": mapping.get("StartingPosition"),
        "filter_patterns": [f["Pattern"] for f in (mapping.get("FilterCriteria") or {}).get("Filters") or []],
        "on_failure_destination": ((mapping.get("DestinationConfig") or {}).get("OnFailure") or {}).get("Destination"),
        "last_processing_result": mapping.get("LastProcessingResult"),
    }


def qualifier(arn):
    """関数 ARN の 8 つ目の要素がエイリアスやバージョン。"""
    parts = arn.split(":")
    return parts[7] if len(parts) > 7 else None


def unqualified(arn):
    return ":".join(arn.split(":")[:7])


def main():
    # AWS_REGION は boto3 の版によっては読まれないので明示的に渡す（未設定ならプロファイルの設定に従う）
    client = boto3.client("lambda", region_name=os.environ.get("AWS_REGION"))
    runtimes = json.loads(RUNTIMES_PATH.read_text())
    run(client, sys.stdout, runtimes)


if __name__ == "__main__":
    main()
