"""SNS トピックの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

import json

from inventory_common import tags_object

TOOL = "sns_inventory.py"
SNAPSHOT_OPTIONS = []
# メールアドレスと電話番号は個人の情報なので出さない
HIDDEN_ENDPOINT_PROTOCOLS = ("email", "email-json", "sms")


def snapshot(ctx, opts):
    topics = ctx.call("sns", "list_topics", {})["Topics"]
    # サブスクリプションはリージョン全体を 1 回で引き、トピック ARN で突き合わせる
    subs = ctx.call("sns", "list_subscriptions", {})["Subscriptions"]
    for t in topics:
        arn = t["TopicArn"]
        own = [s for s in subs if s.get("TopicArn") == arn]
        yield ctx.record("sns_topic", {
            "topic_arn": arn,
            "topic_name": arn.split(":")[-1],
            "fifo": arn.endswith(".fifo"),
            "subscription_count": len(own),
            "subscriptions": [
                {
                    "subscription_arn": s.get("SubscriptionArn"),
                    "protocol": s.get("Protocol"),
                    "endpoint": None if s.get("Protocol") in HIDDEN_ENDPOINT_PROTOCOLS else s.get("Endpoint"),
                    "pending_confirmation": s.get("SubscriptionArn") == "PendingConfirmation",
                }
                for s in own
            ],
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
    """暗号化・配信の状況・アクセスポリシーの要約。"""
    a = ctx.call("sns", "get_topic_attributes", {"TopicArn": record["topic_arn"]}).get("Attributes") or {}
    statements = json.loads(a.get("Policy") or "{}").get("Statement") or []
    return {
        "display_name": a.get("DisplayName"),
        "kms_master_key_id": a.get("KmsMasterKeyId"),
        "subscriptions_confirmed": to_int(a.get("SubscriptionsConfirmed")),
        "subscriptions_pending": to_int(a.get("SubscriptionsPending")),
        "content_based_deduplication": to_bool(a.get("ContentBasedDeduplication")),
        "tracing_config": a.get("TracingConfig"),
        "signature_version": a.get("SignatureVersion"),
        "policy_statement_count": len(statements),
        "policy_public_statement_count": public_statement_count(statements),
    }


def tags(ctx, record):
    return tags_object(ctx.call("sns", "list_tags_for_resource", {"ResourceArn": record["topic_arn"]}).get("Tags"))


DETAIL_KINDS = {
    "attributes": (("sns_topic",), attributes),
    "tags": (("sns_topic",), tags),
}
