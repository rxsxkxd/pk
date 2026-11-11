# frozen_string_literal: true

# セキュリティグループの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-ec2"

module Service
  TOOL = "security_group_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  # 許可のまとまり（IpPermissions）を、許可元・許可先 1 つにつき 1 行のルールに展開する
  def rules(permissions)
    (permissions || []).flat_map do |p|
      sources =
        (p.ip_ranges || []).map { |r| { "source" => r.cidr_ip, "source_type" => "cidr", "description" => r.description } } +
        (p.ipv_6_ranges || []).map { |r| { "source" => r.cidr_ipv_6, "source_type" => "ipv6_cidr", "description" => r.description } } +
        (p.prefix_list_ids || []).map { |r| { "source" => r.prefix_list_id, "source_type" => "prefix_list", "description" => r.description } } +
        (p.user_id_group_pairs || []).map { |r| { "source" => r.group_id, "source_type" => "security_group", "description" => r.description } }
      sources.map { |s| { "protocol" => p.ip_protocol, "from_port" => p.from_port, "to_port" => p.to_port, **s } }
    end
  end

  def referenced_groups(group)
    ((group.ip_permissions || []) + (group.ip_permissions_egress || []))
      .flat_map { |p| (p.user_id_group_pairs || []).map(&:group_id) }
  end

  def snapshot(ctx, _opts)
    ec2 = ctx.client(:EC2)
    groups = ec2.describe_security_groups.flat_map(&:security_groups)
    # どの ENI がどの SG を使っているかを数えるため、リージョンの ENI をまとめて引く
    enis = ec2.describe_network_interfaces.flat_map(&:network_interfaces)
    refs = groups.to_h { |g| [g.group_id, referenced_groups(g)] }

    groups.map do |g|
      gid = g.group_id
      inbound = rules(g.ip_permissions)
      users = enis.select { |n| (n.groups || []).any? { |x| x.group_id == gid } }
      ctx.record("security_group", {
        "group_id" => gid,
        "group_name" => g.group_name,
        "description" => g.description,
        "vpc_id" => g.vpc_id,
        "inbound_rules" => inbound,
        "outbound_rules" => rules(g.ip_permissions_egress),
        "open_to_world" => inbound.any? { |r| ["0.0.0.0/0", "::/0"].include?(r["source"]) },
        "referenced_by" => groups.select { |o| o.group_id != gid && refs[o.group_id].include?(gid) }.map(&:group_id),
        "network_interface_count" => users.size,
        "interface_types" => users.map(&:interface_type).uniq.sort,
        "instance_ids" => users.filter_map { |n| n.attachment&.instance_id }.uniq.sort,
        "tags" => InventoryCommon.tags_object(g.tags),
      })
    end
  end

  # SG を使っている ENI
  def network_interfaces(ctx, record)
    enis = ctx.pace do
      ctx.client(:EC2).describe_network_interfaces(filters: [{ name: "group-id", values: [record["group_id"]] }])
         .flat_map(&:network_interfaces)
    end
    enis.map do |n|
      {
        "network_interface_id" => n.network_interface_id,
        "interface_type" => n.interface_type,
        "description" => n.description,
        "requester_id" => n.requester_id,
        "requester_managed" => n.requester_managed,
        "status" => n.status,
        "private_ip_address" => n.private_ip_address,
        "attachment_instance_id" => n.attachment&.instance_id,
        "subnet_id" => n.subnet_id,
      }
    end
  end

  DETAIL_KINDS = {
    "network_interfaces" => [%w[security_group], :network_interfaces],
  }.freeze
end
