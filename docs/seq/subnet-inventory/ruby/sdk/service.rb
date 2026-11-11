# frozen_string_literal: true

# サブネットの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-ec2"

module Service
  TOOL = "subnet_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  ROUTE_TARGET_METHODS = %i[
    gateway_id nat_gateway_id transit_gateway_id vpc_peering_connection_id network_interface_id
    instance_id egress_only_internet_gateway_id local_gateway_id carrier_gateway_id core_network_arn
  ].freeze

  module_function

  def first_of(obj, methods) = methods.map { |m| obj.public_send(m) }.compact.first

  def snapshot(ctx, _opts)
    ec2 = ctx.client(:EC2)
    subnets = ec2.describe_subnets.flat_map(&:subnets)
    rts = ec2.describe_route_tables.flat_map(&:route_tables)
    subnets.map do |s|
      # 明示的に関連付けたルートテーブルが無ければ、VPC のメインのルートテーブルが使われる
      explicit = rts.find { |rt| (rt.associations || []).any? { |a| a.subnet_id == s.subnet_id } }
      rt = explicit || rts.find { |r| r.vpc_id == s.vpc_id && (r.associations || []).any? { |a| a.main == true } }
      default_route = (rt&.routes || []).find { |r| r.destination_cidr_block == "0.0.0.0/0" }
      default_target = default_route && first_of(default_route, ROUTE_TARGET_METHODS)
      ctx.record("subnet", {
        "subnet_id" => s.subnet_id,
        "subnet_arn" => s.subnet_arn,
        "vpc_id" => s.vpc_id,
        "cidr_block" => s.cidr_block,
        "ipv6_cidr_blocks" => (s.ipv_6_cidr_block_association_set || []).map(&:ipv_6_cidr_block),
        "availability_zone" => s.availability_zone,
        "availability_zone_id" => s.availability_zone_id,
        "available_ip_address_count" => s.available_ip_address_count,
        "map_public_ip_on_launch" => s.map_public_ip_on_launch,
        "default_for_az" => s.default_for_az,
        "state" => s.state,
        "route_table_id" => rt&.route_table_id,
        "route_table_is_main" => explicit.nil? && !rt.nil?,
        "default_route_target" => default_target,
        "is_public" => default_target.to_s.start_with?("igw-"),
        "tags" => InventoryCommon.tags_object(s.tags),
      })
    end
  end

  # サブネットにある ENI（EC2、RDS、Lambda、ALB、Fargate のタスクなど）
  def network_interfaces(ctx, record)
    enis = ctx.pace do
      ctx.client(:EC2).describe_network_interfaces(filters: [{ name: "subnet-id", values: [record["subnet_id"]] }])
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
        "security_group_ids" => (n.groups || []).map(&:group_id),
      }
    end
  end

  DETAIL_KINDS = {
    "network_interfaces" => [%w[subnet], :network_interfaces],
  }.freeze
end
