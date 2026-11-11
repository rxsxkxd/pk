"""ロードバランサー（ELBv2: ALB・NLB・GWLB）とターゲットグループの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。

出力の項目は ../../DATA.md を参照。
"""

from inventory_common import chunked, tags_object, utc_iso

TOOL = "alb_inventory.py"
SNAPSHOT_OPTIONS = []


def snapshot(ctx, opts):
    lbs = ctx.call("elbv2", "describe_load_balancers", {})["LoadBalancers"]
    groups = ctx.call("elbv2", "describe_target_groups", {})["TargetGroups"]

    # タグは 20 件ずつまとめて引く
    arns = [lb["LoadBalancerArn"] for lb in lbs] + [g["TargetGroupArn"] for g in groups]
    tags_by_arn = {}
    for chunk in chunked(arns, 20):
        for d in ctx.call("elbv2", "describe_tags", {"ResourceArns": chunk})["TagDescriptions"]:
            tags_by_arn[d["ResourceArn"]] = tags_object(d.get("Tags"))

    for lb in lbs:
        arn = lb["LoadBalancerArn"]
        yield ctx.record("elbv2_load_balancer", {
            "load_balancer_name": lb.get("LoadBalancerName"),
            "load_balancer_arn": arn,
            "type": lb.get("Type"),
            "scheme": lb.get("Scheme"),
            "state": (lb.get("State") or {}).get("Code"),
            "dns_name": lb.get("DNSName"),
            "vpc_id": lb.get("VpcId"),
            "availability_zones": [
                {"zone_name": z.get("ZoneName"), "subnet_id": z.get("SubnetId")} for z in lb.get("AvailabilityZones") or []
            ],
            "security_group_ids": lb.get("SecurityGroups") or [],
            "ip_address_type": lb.get("IpAddressType"),
            "created_time": utc_iso(lb.get("CreatedTime")),
            "target_group_arns": [g["TargetGroupArn"] for g in groups if arn in (g.get("LoadBalancerArns") or [])],
            "tags": tags_by_arn.get(arn, {}),
        })
    for g in groups:
        yield ctx.record("elbv2_target_group", {
            "target_group_name": g.get("TargetGroupName"),
            "target_group_arn": g["TargetGroupArn"],
            "target_type": g.get("TargetType"),
            "protocol": g.get("Protocol"),
            "port": g.get("Port"),
            "vpc_id": g.get("VpcId"),
            "health_check": {
                "protocol": g.get("HealthCheckProtocol"),
                "path": g.get("HealthCheckPath"),
                "port": g.get("HealthCheckPort"),
                "interval_sec": g.get("HealthCheckIntervalSeconds"),
                "timeout_sec": g.get("HealthCheckTimeoutSeconds"),
                "healthy_threshold": g.get("HealthyThresholdCount"),
                "unhealthy_threshold": g.get("UnhealthyThresholdCount"),
                "matcher": (g.get("Matcher") or {}).get("HttpCode"),
            },
            "load_balancer_arns": g.get("LoadBalancerArns") or [],
            "tags": tags_by_arn.get(g["TargetGroupArn"], {}),
        })


def action(a):
    """リスナーやルールのアクションを要約する。"""
    forward = (a.get("ForwardConfig") or {}).get("TargetGroups")
    if forward is not None:
        target_groups = [t.get("TargetGroupArn") for t in forward]
    elif a.get("TargetGroupArn") is not None:
        target_groups = [a["TargetGroupArn"]]
    else:
        target_groups = []
    return {
        "type": a.get("Type"),
        "target_group_arns": target_groups,
        "redirect_status": (a.get("RedirectConfig") or {}).get("StatusCode"),
        "fixed_response_status": (a.get("FixedResponseConfig") or {}).get("StatusCode"),
    }


def condition_values(c):
    if c.get("Values") is not None:
        return c["Values"]
    for key in ("HostHeaderConfig", "PathPatternConfig", "HttpRequestMethodConfig", "SourceIpConfig"):
        values = (c.get(key) or {}).get("Values")
        if values is not None:
            return values
    return []


def listeners(ctx, record):
    """リスナーと、その振り分けルール。"""
    result = []
    for listener in ctx.call("elbv2", "describe_listeners", {"LoadBalancerArn": record["load_balancer_arn"]})["Listeners"]:
        rules = ctx.call("elbv2", "describe_rules", {"ListenerArn": listener["ListenerArn"]})["Rules"]
        result.append({
            "listener_arn": listener["ListenerArn"],
            "protocol": listener.get("Protocol"),
            "port": listener.get("Port"),
            "ssl_policy": listener.get("SslPolicy"),
            "certificate_arns": [c.get("CertificateArn") for c in listener.get("Certificates") or []],
            "default_actions": [action(a) for a in listener.get("DefaultActions") or []],
            "rules": [
                {
                    "priority": r.get("Priority"),
                    "is_default": r.get("IsDefault"),
                    "conditions": [{"field": c.get("Field"), "values": condition_values(c)} for c in r.get("Conditions") or []],
                    "actions": [action(a) for a in r.get("Actions") or []],
                }
                for r in rules
            ],
        })
    return result


def attributes(ctx, record):
    """ロードバランサーの属性（削除保護・アクセスログ・アイドルタイムアウトなど）。"""
    attrs = ctx.call("elbv2", "describe_load_balancer_attributes", {"LoadBalancerArn": record["load_balancer_arn"]})["Attributes"]
    return {a["Key"]: a.get("Value") for a in attrs}


def target_health(ctx, record):
    """ターゲットグループに登録されたターゲットと、そのヘルス。"""
    descriptions = ctx.call("elbv2", "describe_target_health", {"TargetGroupArn": record["target_group_arn"]})["TargetHealthDescriptions"]
    return [
        {
            "target_id": d["Target"].get("Id"),
            "port": d["Target"].get("Port"),
            "availability_zone": d["Target"].get("AvailabilityZone"),
            "state": (d.get("TargetHealth") or {}).get("State"),
            "reason": (d.get("TargetHealth") or {}).get("Reason"),
            "description": (d.get("TargetHealth") or {}).get("Description"),
        }
        for d in descriptions
    ]


DETAIL_KINDS = {
    "listeners": (("elbv2_load_balancer",), listeners),
    "attributes": (("elbv2_load_balancer",), attributes),
    "target_health": (("elbv2_target_group",), target_health),
}
