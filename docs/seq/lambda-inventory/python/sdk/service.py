"""Lambda 関数の棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

import json
from pathlib import Path

from inventory_common import utc_iso

TOOL = "lambda_inventory.py"
SNAPSHOT_OPTIONS = []
RUNTIMES = json.loads((Path(__file__).resolve().parent / "runtimes.json").read_text())


def qualifier(arn):
    """関数 ARN の 8 つ目の要素がエイリアスやバージョン。"""
    parts = arn.split(":")
    return parts[7] if len(parts) > 7 else None


def unqualified(arn):
    return ":".join(arn.split(":")[:7])


def snapshot(ctx, opts):
    functions = ctx.call("lambda", "list_functions", {})["Functions"]
    # イベントソースマッピングはリージョン全体を 1 回で引き、関数 ARN で突き合わせる
    mappings = ctx.call("lambda", "list_event_source_mappings", {})["EventSourceMappings"]
    for fn in functions:
        own = [m for m in mappings if unqualified(m["FunctionArn"]) == fn["FunctionArn"]]
        yield function_record(ctx, fn, own)


def function_record(ctx, fn, mappings):
    vpc = fn.get("VpcConfig") or {}
    logging = fn.get("LoggingConfig") or {}
    image = fn.get("PackageType") == "Image"
    return ctx.record("lambda_function", {
        "function_name": fn["FunctionName"],
        "function_arn": fn["FunctionArn"],
        "description": fn.get("Description"),
        "package_type": fn.get("PackageType") or "Zip",
        "runtime": fn.get("Runtime"),
        "handler": fn.get("Handler"),
        "architecture": (fn.get("Architectures") or ["x86_64"])[0],
        "base_os": "Container Image" if image else RUNTIMES.get(fn.get("Runtime") or "", "Unknown"),
        "memory_mb": fn.get("MemorySize"),
        "timeout_sec": fn.get("Timeout"),
        "ephemeral_storage_mb": (fn.get("EphemeralStorage") or {}).get("Size"),
        "code_size_bytes": fn.get("CodeSize"),
        "last_modified": utc_iso(fn.get("LastModified")),
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
        "event_source_mappings": [mapping_entry(m) for m in mappings],
    })


def mapping_entry(m):
    endpoints = (m.get("SelfManagedEventSource") or {}).get("Endpoints") or {}
    return {
        "uuid": m.get("UUID"),
        "event_source": m.get("EventSourceArn"),
        "self_managed_endpoints": endpoints.get("KAFKA_BOOTSTRAP_SERVERS"),
        "topics": m.get("Topics") or [],
        "qualifier": qualifier(m["FunctionArn"]),
        "state": m.get("State"),
        "batch_size": m.get("BatchSize"),
        "maximum_batching_window_sec": m.get("MaximumBatchingWindowInSeconds"),
        "starting_position": m.get("StartingPosition"),
        "filter_patterns": [f["Pattern"] for f in (m.get("FilterCriteria") or {}).get("Filters") or []],
        "on_failure_destination": ((m.get("DestinationConfig") or {}).get("OnFailure") or {}).get("Destination"),
        "last_processing_result": m.get("LastProcessingResult"),
    }


def policy(ctx, record):
    """リソースベースポリシーで呼び出しを許可している相手。ポリシーが無ければ []。"""
    result = ctx.call_or_none(("ResourceNotFoundException",), "lambda", "get_policy", {"FunctionName": record["function_name"]})
    statements = json.loads((result or {}).get("Policy") or "{}").get("Statement") or []
    entries = []
    for st in statements:
        principal = st.get("Principal")
        if isinstance(principal, dict):
            principal = principal.get("Service") or principal.get("AWS")
        condition = st.get("Condition") or {}
        entries.append({
            "sid": st.get("Sid"),
            "effect": st.get("Effect"),
            "principal": principal,
            "action": st.get("Action"),
            "source_arn": (condition.get("ArnLike") or {}).get("AWS:SourceArn")
            or (condition.get("ArnEquals") or {}).get("AWS:SourceArn"),
            "source_account": (condition.get("StringEquals") or {}).get("AWS:SourceAccount"),
            "function_url_auth_type": (condition.get("StringEquals") or {}).get("lambda:FunctionUrlAuthType"),
        })
    return entries


DETAIL_KINDS = {
    "policy": (("lambda_function",), policy),
}
