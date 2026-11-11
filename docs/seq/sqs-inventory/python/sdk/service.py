"""SQS キューの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

import json

from inventory_common import epoch_iso

TOOL = "sqs_inventory.py"
SNAPSHOT_OPTIONS = []


def snapshot(ctx, opts):
    # キューが 1 つも無いと、QueueUrls そのものが返らない
    for url in ctx.call("sqs", "list_queues", {}).get("QueueUrls") or []:
        yield ctx.record("sqs_queue", {
            "queue_url": url,
            "queue_name": url.split("/")[-1],
            "fifo": url.endswith(".fifo"),
        })


def public_statement_count(statements):
    """条件なしで、だれにでも（Principal が *）許可している文の数。"""
    count = 0
    for st in statements:
        principal = st.get("Principal")
        if isinstance(principal, dict):
            principal = principal.get("AWS")
        principals = principal if isinstance(principal, list) else [principal]
        if st.get("Effect") == "Allow" and st.get("Condition") is None and "*" in principals:
            count += 1
    return count


def to_int(value):
    return None if value is None else int(value)


def to_bool(value):
    return None if value is None else value == "true"


def attributes(ctx, record):
    """キューの設定・溜まっているメッセージ数・デッドレターキュー・暗号化・アクセスポリシーの要約。"""
    a = ctx.call("sqs", "get_queue_attributes", {"QueueUrl": record["queue_url"], "AttributeNames": ["All"]}).get("Attributes") or {}
    redrive = json.loads(a.get("RedrivePolicy") or "{}")
    statements = json.loads(a.get("Policy") or "{}").get("Statement") or []
    return {
        "queue_arn": a.get("QueueArn"),
        "visibility_timeout_sec": to_int(a.get("VisibilityTimeout")),
        "message_retention_sec": to_int(a.get("MessageRetentionPeriod")),
        "maximum_message_size": to_int(a.get("MaximumMessageSize")),
        "delay_sec": to_int(a.get("DelaySeconds")),
        "receive_wait_time_sec": to_int(a.get("ReceiveMessageWaitTimeSeconds")),
        "approximate_messages": to_int(a.get("ApproximateNumberOfMessages")),
        "approximate_messages_not_visible": to_int(a.get("ApproximateNumberOfMessagesNotVisible")),
        "approximate_messages_delayed": to_int(a.get("ApproximateNumberOfMessagesDelayed")),
        "dead_letter_target_arn": redrive.get("deadLetterTargetArn"),
        "max_receive_count": redrive.get("maxReceiveCount"),
        "kms_master_key_id": a.get("KmsMasterKeyId"),
        "sqs_managed_sse_enabled": to_bool(a.get("SqsManagedSseEnabled")),
        "content_based_deduplication": to_bool(a.get("ContentBasedDeduplication")),
        "created_at": epoch_iso(a.get("CreatedTimestamp")),
        "last_modified_at": epoch_iso(a.get("LastModifiedTimestamp")),
        "policy_statement_count": len(statements),
        "policy_public_statement_count": public_statement_count(statements),
    }


def tags(ctx, record):
    return ctx.call("sqs", "list_queue_tags", {"QueueUrl": record["queue_url"]}).get("Tags") or {}


DETAIL_KINDS = {
    "attributes": (("sqs_queue",), attributes),
    "tags": (("sqs_queue",), tags),
}
