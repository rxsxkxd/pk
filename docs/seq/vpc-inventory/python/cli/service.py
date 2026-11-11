"""VPC の棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from inventory_common import tags_object

TOOL = "vpc_inventory.py"
SNAPSHOT_OPTIONS = []

ROUTE_TARGET_KEYS = [
    "GatewayId", "NatGatewayId", "TransitGatewayId", "VpcPeeringConnectionId", "NetworkInterfaceId",
    "InstanceId", "EgressOnlyInternetGatewayId", "LocalGatewayId", "CarrierGatewayId", "CoreNetworkArn",
]


def first_of(d, keys):
    return next((d[k] for k in keys if d.get(k) is not None), None)


def snapshot(ctx, opts):
    vpcs = ctx.call("ec2", "describe_vpcs", {})["Vpcs"]
    route_tables = ctx.call("ec2", "describe_route_tables", {})["RouteTables"]
    igws = ctx.call("ec2", "describe_internet_gateways", {})["InternetGateways"]
    nats = ctx.call("ec2", "describe_nat_gateways", {})["NatGateways"]
    endpoints = ctx.call("ec2", "describe_vpc_endpoints", {})["VpcEndpoints"]
    peerings = ctx.call("ec2", "describe_vpc_peering_connections", {})["VpcPeeringConnections"]
    subnets = ctx.call("ec2", "describe_subnets", {})["Subnets"]

    for v in vpcs:
        vpc = v["VpcId"]
        yield ctx.record("vpc", {
            "vpc_id": vpc,
            "cidr_block": v.get("CidrBlock"),
            "cidr_blocks": [a.get("CidrBlock") for a in v.get("CidrBlockAssociationSet") or []],
            "ipv6_cidr_blocks": [a.get("Ipv6CidrBlock") for a in v.get("Ipv6CidrBlockAssociationSet") or []],
            "state": v.get("State"),
            "is_default": v.get("IsDefault"),
            "dhcp_options_id": v.get("DhcpOptionsId"),
            "instance_tenancy": v.get("InstanceTenancy"),
            "subnet_count": len([s for s in subnets if s.get("VpcId") == vpc]),
            "internet_gateway_ids": [
                g["InternetGatewayId"] for g in igws if any(a.get("VpcId") == vpc for a in g.get("Attachments") or [])
            ],
            "nat_gateways": [
                {
                    "nat_gateway_id": n.get("NatGatewayId"),
                    "subnet_id": n.get("SubnetId"),
                    "state": n.get("State"),
                    "connectivity_type": n.get("ConnectivityType"),
                    "public_ip": (n.get("NatGatewayAddresses") or [{}])[0].get("PublicIp"),
                }
                for n in nats if n.get("VpcId") == vpc and n.get("State") != "deleted"
            ],
            "vpc_endpoints": [
                {"vpc_endpoint_id": e.get("VpcEndpointId"), "service_name": e.get("ServiceName"),
                 "type": e.get("VpcEndpointType"), "state": e.get("State")}
                for e in endpoints if e.get("VpcId") == vpc
            ],
            "peering_connections": [
                {
                    "vpc_peering_connection_id": p.get("VpcPeeringConnectionId"),
                    "status": (p.get("Status") or {}).get("Code"),
                    "requester_vpc_id": (p.get("RequesterVpcInfo") or {}).get("VpcId"),
                    "accepter_vpc_id": (p.get("AccepterVpcInfo") or {}).get("VpcId"),
                }
                for p in peerings
                if vpc in ((p.get("RequesterVpcInfo") or {}).get("VpcId"), (p.get("AccepterVpcInfo") or {}).get("VpcId"))
                and (p.get("Status") or {}).get("Code") != "deleted"
            ],
            "route_tables": [
                {
                    "route_table_id": rt.get("RouteTableId"),
                    "main": any(a.get("Main") is True for a in rt.get("Associations") or []),
                    "subnet_ids": [a["SubnetId"] for a in rt.get("Associations") or [] if a.get("SubnetId") is not None],
                    "routes": [
                        {
                            "destination": first_of(r, ["DestinationCidrBlock", "DestinationIpv6CidrBlock", "DestinationPrefixListId"]),
                            "target": first_of(r, ROUTE_TARGET_KEYS),
                            "state": r.get("State"),
                        }
                        for r in rt.get("Routes") or []
                    ],
                }
                for rt in route_tables if rt.get("VpcId") == vpc
            ],
            "tags": tags_object(v.get("Tags")),
        })


def flow_logs(ctx, record):
    """VPC に設定したフローログ。"""
    params = {"Filter": [{"Name": "resource-id", "Values": [record["vpc_id"]]}]}
    return [
        {
            "flow_log_id": f.get("FlowLogId"),
            "traffic_type": f.get("TrafficType"),
            "log_destination_type": f.get("LogDestinationType"),
            "log_destination": f.get("LogDestination"),
            "status": f.get("FlowLogStatus"),
            "deliver_logs_status": f.get("DeliverLogsStatus"),
        }
        for f in ctx.call("ec2", "describe_flow_logs", params)["FlowLogs"]
    ]


DETAIL_KINDS = {
    "flow_logs": (("vpc",), flow_logs),
}
