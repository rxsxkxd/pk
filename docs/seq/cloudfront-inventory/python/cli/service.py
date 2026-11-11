"""CloudFront ディストリビューションの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from inventory_common import tags_object, utc_iso

TOOL = "cloudfront_inventory.py"
SNAPSHOT_OPTIONS = []


def origin_type(o):
    if o.get("VpcOriginConfig") is not None:
        return "vpc"
    if o.get("S3OriginConfig") is not None:
        return "s3"
    return "custom"


def snapshot(ctx, opts):
    # CloudFront はリージョンをまたぐサービスなので、region は global にする
    items = (ctx.call("cloudfront", "list_distributions", {}).get("DistributionList") or {}).get("Items") or []
    for d in items:
        cert = d.get("ViewerCertificate") or {}
        dcb = d.get("DefaultCacheBehavior") or {}
        yield ctx.record("cloudfront_distribution", {
            "region": "global",
            "distribution_id": d.get("Id"),
            "arn": d.get("ARN"),
            "domain_name": d.get("DomainName"),
            "aliases": (d.get("Aliases") or {}).get("Items") or [],
            "status": d.get("Status"),
            "enabled": d.get("Enabled"),
            "comment": d.get("Comment"),
            "price_class": d.get("PriceClass"),
            "http_version": d.get("HttpVersion"),
            "is_ipv6_enabled": d.get("IsIPV6Enabled"),
            "web_acl_id": d.get("WebACLId"),
            "staging": d.get("Staging"),
            "viewer_certificate": {
                "acm_certificate_arn": cert.get("ACMCertificateArn"),
                "cloudfront_default_certificate": cert.get("CloudFrontDefaultCertificate"),
                "minimum_protocol_version": cert.get("MinimumProtocolVersion"),
                "ssl_support_method": cert.get("SSLSupportMethod"),
            },
            "origins": [
                {
                    "id": o.get("Id"),
                    "domain_name": o.get("DomainName"),
                    "origin_path": o.get("OriginPath"),
                    "origin_type": origin_type(o),
                    "origin_access_control_id": o.get("OriginAccessControlId"),
                    "origin_protocol_policy": (o.get("CustomOriginConfig") or {}).get("OriginProtocolPolicy"),
                }
                for o in (d.get("Origins") or {}).get("Items") or []
            ],
            "default_cache_behavior": {
                "target_origin_id": dcb.get("TargetOriginId"),
                "viewer_protocol_policy": dcb.get("ViewerProtocolPolicy"),
                "cache_policy_id": dcb.get("CachePolicyId"),
                "origin_request_policy_id": dcb.get("OriginRequestPolicyId"),
                "function_count": (dcb.get("FunctionAssociations") or {}).get("Quantity") or 0,
                "lambda_function_count": (dcb.get("LambdaFunctionAssociations") or {}).get("Quantity") or 0,
            },
            "cache_behavior_count": (d.get("CacheBehaviors") or {}).get("Quantity") or 0,
            "geo_restriction": ((d.get("Restrictions") or {}).get("GeoRestriction") or {}).get("RestrictionType"),
            "last_modified_time": utc_iso(d.get("LastModifiedTime")),
        })


def config(ctx, record):
    """一覧に入っていない設定（既定のルートオブジェクト・アクセスログ・エラーページなど）。"""
    c = ctx.call("cloudfront", "get_distribution_config", {"Id": record["distribution_id"]}).get("DistributionConfig") or {}
    logging = c.get("Logging") or {}
    return {
        "default_root_object": c.get("DefaultRootObject"),
        "logging_enabled": logging.get("Enabled"),
        "logging_bucket": logging.get("Bucket"),
        "logging_prefix": logging.get("Prefix"),
        "custom_error_response_count": (c.get("CustomErrorResponses") or {}).get("Quantity") or 0,
        "continuous_deployment_policy_id": c.get("ContinuousDeploymentPolicyId"),
    }


def tags(ctx, record):
    result = ctx.call("cloudfront", "list_tags_for_resource", {"Resource": record["arn"]})
    return tags_object((result.get("Tags") or {}).get("Items"))


DETAIL_KINDS = {
    "config": (("cloudfront_distribution",), config),
    "tags": (("cloudfront_distribution",), tags),
}
