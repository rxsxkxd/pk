"""WAF（wafv2）の Web ACL の棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

TOOL = "waf_inventory.py"
SNAPSHOT_OPTIONS = [("--scope", "REGIONAL か CLOUDFRONT。指定しなければ両方")]
REGIONAL_RESOURCE_TYPES = ["APPLICATION_LOAD_BALANCER", "API_GATEWAY", "APPSYNC", "COGNITO_USER_POOL"]


def scope_region(ctx, scope):
    """CLOUDFRONT スコープの Web ACL は us-east-1 にある。"""
    return "us-east-1" if scope == "CLOUDFRONT" else ctx.aws.region


def list_web_acls(ctx, scope):
    """ListWebACLs は NextMarker を自分でたどる。"""
    acls = []
    marker = None
    while True:
        params = {"Scope": scope}
        if marker:
            params["NextMarker"] = marker
        page = ctx.call("wafv2", "list_web_acls", params, scope_region(ctx, scope))
        acls += page.get("WebACLs") or []
        marker = page.get("NextMarker")
        if not marker:
            return acls


def snapshot(ctx, opts):
    for scope in opts["scope"] or ["REGIONAL", "CLOUDFRONT"]:
        for acl in list_web_acls(ctx, scope):
            yield ctx.record("wafv2_web_acl", {
                "region": "global" if scope == "CLOUDFRONT" else ctx.common["region"],
                "scope": scope,
                "name": acl.get("Name"),
                "id": acl.get("Id"),
                "arn": acl.get("ARN"),
                "description": acl.get("Description"),
            })


def first_key(obj):
    return next(iter(obj)) if obj else None


def rules(ctx, record):
    """既定のアクションと、ルールの一覧（優先度・アクション・種類・マネージドルールグループ）。"""
    params = {"Scope": record["scope"], "Name": record["name"], "Id": record["id"]}
    acl = ctx.call("wafv2", "get_web_acl", params, scope_region(ctx, record["scope"])).get("WebACL") or {}
    result = []
    for r in acl.get("Rules") or []:
        statement = r.get("Statement") or {}
        managed = statement.get("ManagedRuleGroupStatement")
        result.append({
            "name": r.get("Name"),
            "priority": r.get("Priority"),
            "action": first_key(r["Action"]) if r.get("Action") is not None else f"override:{first_key(r.get('OverrideAction'))}",
            "statement_type": first_key(statement),
            "managed_rule_group": f"{managed.get('VendorName')}/{managed.get('Name')}" if managed is not None else None,
            "rule_group_arn": (statement.get("RuleGroupReferenceStatement") or {}).get("ARN"),
        })
    return {"default_action": first_key(acl.get("DefaultAction")), "capacity": acl.get("Capacity"), "rules": result}


def resources(ctx, record):
    """Web ACL を関連付けている先。CLOUDFRONT スコープはディストリビューション、REGIONAL は ALB・API Gateway など。"""
    if record["scope"] == "CLOUDFRONT":
        result = ctx.call("cloudfront", "list_distributions_by_web_acl_id", {"WebACLId": record["arn"]})
        items = (result.get("DistributionList") or {}).get("Items") or []
        return [{"resource_type": "CLOUDFRONT_DISTRIBUTION", "resource_arn": d.get("ARN")} for d in items]
    result = []
    for resource_type in REGIONAL_RESOURCE_TYPES:
        params = {"WebACLArn": record["arn"], "ResourceType": resource_type}
        for arn in ctx.call("wafv2", "list_resources_for_web_acl", params).get("ResourceArns") or []:
            result.append({"resource_type": resource_type, "resource_arn": arn})
    return result


def logging(ctx, record):
    """ログの出力先。ログを設定していなければ None。"""
    config = ctx.call_or_none(("WAFNonexistentItemException",), "wafv2", "get_logging_configuration",
                              {"ResourceArn": record["arn"]}, scope_region(ctx, record["scope"]))
    if config is None:
        return None
    return {"log_destinations": (config.get("LoggingConfiguration") or {}).get("LogDestinationConfigs") or []}


DETAIL_KINDS = {
    "rules": (("wafv2_web_acl",), rules),
    "resources": (("wafv2_web_acl",), resources),
    "logging": (("wafv2_web_acl",), logging),
}
