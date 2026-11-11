"""セキュリティグループの棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from inventory_common import tags_object

TOOL = "security_group_inventory.py"
SNAPSHOT_OPTIONS = []


def rules(permissions):
    """許可のまとまり（IpPermissions）を、許可元・許可先 1 つにつき 1 行のルールに展開する。"""
    result = []
    for p in permissions or []:
        sources = (
            [{"source": r.get("CidrIp"), "source_type": "cidr", "description": r.get("Description")}
             for r in p.get("IpRanges") or []]
            + [{"source": r.get("CidrIpv6"), "source_type": "ipv6_cidr", "description": r.get("Description")}
               for r in p.get("Ipv6Ranges") or []]
            + [{"source": r.get("PrefixListId"), "source_type": "prefix_list", "description": r.get("Description")}
               for r in p.get("PrefixListIds") or []]
            + [{"source": r.get("GroupId"), "source_type": "security_group", "description": r.get("Description")}
               for r in p.get("UserIdGroupPairs") or []]
        )
        for s in sources:
            result.append({"protocol": p.get("IpProtocol"), "from_port": p.get("FromPort"), "to_port": p.get("ToPort"), **s})
    return result


def referenced_groups(group):
    perms = (group.get("IpPermissions") or []) + (group.get("IpPermissionsEgress") or [])
    return {pair.get("GroupId") for p in perms for pair in p.get("UserIdGroupPairs") or []}


def snapshot(ctx, opts):
    groups = ctx.call("ec2", "describe_security_groups", {})["SecurityGroups"]
    # どの ENI がどの SG を使っているかを数えるため、リージョンの ENI をまとめて引く
    enis = ctx.call("ec2", "describe_network_interfaces", {})["NetworkInterfaces"]
    refs = {g["GroupId"]: referenced_groups(g) for g in groups}

    for g in groups:
        gid = g["GroupId"]
        inbound = rules(g.get("IpPermissions"))
        users = [n for n in enis if any(x.get("GroupId") == gid for x in n.get("Groups") or [])]
        yield ctx.record("security_group", {
            "group_id": gid,
            "group_name": g.get("GroupName"),
            "description": g.get("Description"),
            "vpc_id": g.get("VpcId"),
            "inbound_rules": inbound,
            "outbound_rules": rules(g.get("IpPermissionsEgress")),
            "open_to_world": any(r["source"] in ("0.0.0.0/0", "::/0") for r in inbound),
            "referenced_by": [other["GroupId"] for other in groups if other["GroupId"] != gid and gid in refs[other["GroupId"]]],
            "network_interface_count": len(users),
            "interface_types": sorted({n.get("InterfaceType") for n in users}),
            "instance_ids": sorted({(n.get("Attachment") or {}).get("InstanceId") for n in users} - {None}),
            "tags": tags_object(g.get("Tags")),
        })


def network_interfaces(ctx, record):
    """SG を使っている ENI。"""
    params = {"Filters": [{"Name": "group-id", "Values": [record["group_id"]]}]}
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
            "subnet_id": n.get("SubnetId"),
        }
        for n in ctx.call("ec2", "describe_network_interfaces", params)["NetworkInterfaces"]
    ]


DETAIL_KINDS = {
    "network_interfaces": (("security_group",), network_interfaces),
}
