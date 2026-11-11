"""サブネットの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from inventory_common import tags_object

TOOL = "subnet_inventory.py"
SNAPSHOT_OPTIONS = []

ROUTE_TARGET_KEYS = [
    "GatewayId", "NatGatewayId", "TransitGatewayId", "VpcPeeringConnectionId", "NetworkInterfaceId",
    "InstanceId", "EgressOnlyInternetGatewayId", "LocalGatewayId", "CarrierGatewayId", "CoreNetworkArn",
]


def first_of(d, keys):
    return next((d[k] for k in keys if d.get(k) is not None), None)


def snapshot(ctx, opts):
    subnets = ctx.call("ec2", "describe_subnets", {})["Subnets"]
    rts = ctx.call("ec2", "describe_route_tables", {})["RouteTables"]
    for s in subnets:
        # 明示的に関連付けたルートテーブルが無ければ、VPC のメインのルートテーブルが使われる
        explicit = next((rt for rt in rts if any(a.get("SubnetId") == s["SubnetId"] for a in rt.get("Associations") or [])), None)
        rt = explicit or next(
            (rt for rt in rts if rt.get("VpcId") == s["VpcId"] and any(a.get("Main") is True for a in rt.get("Associations") or [])),
            None)
        default_route = next((r for r in (rt or {}).get("Routes") or [] if r.get("DestinationCidrBlock") == "0.0.0.0/0"), None)
        default_target = first_of(default_route, ROUTE_TARGET_KEYS) if default_route else None
        yield ctx.record("subnet", {
            "subnet_id": s["SubnetId"],
            "subnet_arn": s.get("SubnetArn"),
            "vpc_id": s.get("VpcId"),
            "cidr_block": s.get("CidrBlock"),
            "ipv6_cidr_blocks": [a.get("Ipv6CidrBlock") for a in s.get("Ipv6CidrBlockAssociationSet") or []],
            "availability_zone": s.get("AvailabilityZone"),
            "availability_zone_id": s.get("AvailabilityZoneId"),
            "available_ip_address_count": s.get("AvailableIpAddressCount"),
            "map_public_ip_on_launch": s.get("MapPublicIpOnLaunch"),
            "default_for_az": s.get("DefaultForAz"),
            "state": s.get("State"),
            "route_table_id": (rt or {}).get("RouteTableId"),
            "route_table_is_main": explicit is None and rt is not None,
            "default_route_target": default_target,
            "is_public": (default_target or "").startswith("igw-"),
            "tags": tags_object(s.get("Tags")),
        })


def network_interfaces(ctx, record):
    """サブネットにある ENI（EC2、RDS、Lambda、ALB、Fargate のタスクなど）。"""
    params = {"Filters": [{"Name": "subnet-id", "Values": [record["subnet_id"]]}]}
    return [
        {
            "network_interface_id": n.get("NetworkInterfaceId"),
            "interface_type": n.get("InterfaceType"),
            "description": n.get("Description"),
            "requester_id": n.get("RequesterId"),
            "requester_managed": n.get("RequesterManaged"),
            "status": n.get("Status"),
            "private_ip_address": n.get("PrivateIpAddress"),
            "attachment_instance_id": (n.get("Attachment") or {}).get("InstanceId"),
            "security_group_ids": [g.get("GroupId") for g in n.get("Groups") or []],
        }
        for n in ctx.call("ec2", "describe_network_interfaces", params)["NetworkInterfaces"]
    ]


DETAIL_KINDS = {
    "network_interfaces": (("subnet",), network_interfaces),
}
