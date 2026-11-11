"""S3 バケットの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from inventory_common import tags_object, utc_iso

TOOL = "s3_inventory.py"
SNAPSHOT_OPTIONS = []


def snapshot(ctx, opts):
    # バケットの一覧はリージョンをまたいで返る。region にはバケットのあるリージョンを入れる
    for b in ctx.call("s3", "list_buckets", {})["Buckets"]:
        yield ctx.record("s3_bucket", {
            "region": b.get("BucketRegion"),
            "bucket_name": b["Name"],
            "creation_date": utc_iso(b.get("CreationDate")),
        })


def _call_or_none(ctx, record, codes, operation):
    """バケットのあるリージョンに向けて呼ぶ。「設定が無い」エラーなら None。"""
    return ctx.call_or_none(codes, "s3", operation, {"Bucket": record["bucket_name"]}, record.get("region"))


def security(ctx, record):
    """暗号化・パブリックアクセスブロック・バケットポリシーの公開状態・オブジェクトの所有者。"""
    enc = _call_or_none(ctx, record, ("ServerSideEncryptionConfigurationNotFoundError",), "get_bucket_encryption")
    pab = _call_or_none(ctx, record, ("NoSuchPublicAccessBlockConfiguration",), "get_public_access_block")
    status = _call_or_none(ctx, record, ("NoSuchBucketPolicy",), "get_bucket_policy_status")
    own = _call_or_none(ctx, record, ("OwnershipControlsNotFoundError",), "get_bucket_ownership_controls")

    rules = ((enc or {}).get("ServerSideEncryptionConfiguration") or {}).get("Rules") or []
    rule = rules[0] if rules else None
    block = (pab or {}).get("PublicAccessBlockConfiguration")
    ownership_rules = ((own or {}).get("OwnershipControls") or {}).get("Rules") or []
    return {
        "encryption": {
            "algorithm": (rule.get("ApplyServerSideEncryptionByDefault") or {}).get("SSEAlgorithm"),
            "kms_key_id": (rule.get("ApplyServerSideEncryptionByDefault") or {}).get("KMSMasterKeyID"),
            "bucket_key_enabled": rule.get("BucketKeyEnabled"),
        } if rule else None,
        "public_access_block": {
            "block_public_acls": block.get("BlockPublicAcls"),
            "ignore_public_acls": block.get("IgnorePublicAcls"),
            "block_public_policy": block.get("BlockPublicPolicy"),
            "restrict_public_buckets": block.get("RestrictPublicBuckets"),
        } if block else None,
        "has_policy": status is not None,
        "policy_is_public": ((status or {}).get("PolicyStatus") or {}).get("IsPublic"),
        "object_ownership": ownership_rules[0].get("ObjectOwnership") if ownership_rules else None,
    }


def management(ctx, record):
    """バージョニング・ライフサイクル・アクセスログ。"""
    ver = _call_or_none(ctx, record, (), "get_bucket_versioning") or {}
    life = _call_or_none(ctx, record, ("NoSuchLifecycleConfiguration",), "get_bucket_lifecycle_configuration") or {}
    log = (_call_or_none(ctx, record, (), "get_bucket_logging") or {}).get("LoggingEnabled") or {}
    rules = life.get("Rules") or []
    return {
        "versioning": ver.get("Status"),
        "mfa_delete": ver.get("MFADelete"),
        "lifecycle_rule_count": len(rules),
        "lifecycle_enabled_rule_count": len([r for r in rules if r.get("Status") == "Enabled"]),
        "logging_target_bucket": log.get("TargetBucket"),
        "logging_target_prefix": log.get("TargetPrefix"),
    }


def tags(ctx, record):
    """タグ。付いていなければ {}。"""
    result = _call_or_none(ctx, record, ("NoSuchTagSet",), "get_bucket_tagging") or {}
    return tags_object(result.get("TagSet"))


DETAIL_KINDS = {
    "security": (("s3_bucket",), security),
    "management": (("s3_bucket",), management),
    "tags": (("s3_bucket",), tags),
}
