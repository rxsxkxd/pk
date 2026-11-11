# frozen_string_literal: true

# セキュリティグループの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "security_group_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  # 許可のまとまり（IpPermissions）を、許可元・許可先 1 つにつき 1 行のルールに展開する
  def rules(permissions)
    (permissions || []).flat_map do |p|
      sources =
        (p["IpRanges"] || []).map { |r| { "source" => r["CidrIp"], "source_type" => "cidr", "description" => r["Description"] } } +
        (p["Ipv6Ranges"] || []).map { |r| { "source" => r["CidrIpv6"], "source_type" => "ipv6_cidr", "description" => r["Description"] } } +
        (p["PrefixListIds"] || []).map { |r| { "source" => r["PrefixListId"], "source_type" => "prefix_list", "description" => r["Description"] } } +
        (p["UserIdGroupPairs"] || []).map { |r| { "source" => r["GroupId"], "source_type" => "security_group", "description" => r["Description"] } }
      sources.map { |s| { "protocol" => p["IpProtocol"], "from_port" => p["FromPort"], "to_port" => p["ToPort"], **s } }
    end
  end

  def referenced_groups(group)
    ((group["IpPermissions"] || []) + (group["IpPermissionsEgress"] || []))
      .flat_map { |p| (p["UserIdGroupPairs"] || []).map { |pair| pair["GroupId"] } }
  end

  def snapshot(ctx, _opts)
    groups = ctx.call("ec2", "describe_security_groups")["SecurityGroups"]
    # どの ENI がどの SG を使っているかを数えるため、リージョンの ENI をまとめて引く
    enis = ctx.call("ec2", "describe_network_interfaces")["NetworkInterfaces"]
    refs = groups.to_h { |g| [g["GroupId"], referenced_groups(g)] }

    groups.map do |g|
      gid = g["GroupId"]
      inbound = rules(g["IpPermissions"])
      users = enis.select { |n| (n["Groups"] || []).any? { |x| x["GroupId"] == gid } }
      ctx.record("security_group", {
        "group_id" => gid,
        "group_name" => g["GroupName"],
        "description" => g["Description"],
        "vpc_id" => g["VpcId"],
        "inbound_rules" => inbound,
        "outbound_rules" => rules(g["IpPermissionsEgress"]),
        "open_to_world" => inbound.any? { |r| ["0.0.0.0/0", "::/0"].include?(r["source"]) },
        "referenced_by" => groups.select { |o| o["GroupId"] != gid && refs[o["GroupId"]].include?(gid) }.map { |o| o["GroupId"] },
        "network_interface_count" => users.size,
        "interface_types" => users.map { |n| n["InterfaceType"] }.uniq.sort,
        "instance_ids" => users.filter_map { |n| n.dig("Attachment", "InstanceId") }.uniq.sort,
        "tags" => InventoryCommon.tags_object(g["Tags"]),
      })
    end
  end

  # SG を使っている ENI
  def network_interfaces(ctx, record)
    params = { "Filters" => [{ "Name" => "group-id", "Values" => [record["group_id"]] }] }
    ctx.call("ec2", "describe_network_interfaces", params)["NetworkInterfaces"].map do |n|
      {
        "network_interface_id" => n["NetworkInterfaceId"],
        "interface_type" => n["InterfaceType"],
        "description" => n["Description"],
        "requester_id" => n["RequesterId"],
        "requester_managed" => n["RequesterManaged"],
        "status" => n["Status"],
        "private_ip_address" => n["PrivateIpAddress"],
        "attachment_instance_id" => n.dig("Attachment", "InstanceId"),
        "subnet_id" => n["SubnetId"],
      }
    end
  end

  DETAIL_KINDS = {
    "network_interfaces" => [%w[security_group], :network_interfaces],
  }.freeze
end
