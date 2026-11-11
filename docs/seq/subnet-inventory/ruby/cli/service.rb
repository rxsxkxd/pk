# frozen_string_literal: true

# サブネットの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "subnet_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  ROUTE_TARGET_KEYS = %w[
    GatewayId NatGatewayId TransitGatewayId VpcPeeringConnectionId NetworkInterfaceId
    InstanceId EgressOnlyInternetGatewayId LocalGatewayId CarrierGatewayId CoreNetworkArn
  ].freeze

  module_function

  def first_of(hash, keys) = keys.map { |k| hash[k] }.compact.first

  def snapshot(ctx, _opts)
    subnets = ctx.call("ec2", "describe_subnets")["Subnets"]
    rts = ctx.call("ec2", "describe_route_tables")["RouteTables"]
    subnets.map do |s|
      # 明示的に関連付けたルートテーブルが無ければ、VPC のメインのルートテーブルが使われる
      explicit = rts.find { |rt| (rt["Associations"] || []).any? { |a| a["SubnetId"] == s["SubnetId"] } }
      rt = explicit || rts.find { |r| r["VpcId"] == s["VpcId"] && (r["Associations"] || []).any? { |a| a["Main"] == true } }
      default_route = (rt&.dig("Routes") || []).find { |r| r["DestinationCidrBlock"] == "0.0.0.0/0" }
      default_target = default_route && first_of(default_route, ROUTE_TARGET_KEYS)
      ctx.record("subnet", {
        "subnet_id" => s["SubnetId"],
        "subnet_arn" => s["SubnetArn"],
        "vpc_id" => s["VpcId"],
        "cidr_block" => s["CidrBlock"],
        "ipv6_cidr_blocks" => (s["Ipv6CidrBlockAssociationSet"] || []).map { |a| a["Ipv6CidrBlock"] },
        "availability_zone" => s["AvailabilityZone"],
        "availability_zone_id" => s["AvailabilityZoneId"],
        "available_ip_address_count" => s["AvailableIpAddressCount"],
        "map_public_ip_on_launch" => s["MapPublicIpOnLaunch"],
        "default_for_az" => s["DefaultForAz"],
        "state" => s["State"],
        "route_table_id" => rt&.dig("RouteTableId"),
        "route_table_is_main" => explicit.nil? && !rt.nil?,
        "default_route_target" => default_target,
        "is_public" => default_target.to_s.start_with?("igw-"),
        "tags" => InventoryCommon.tags_object(s["Tags"]),
      })
    end
  end

  # サブネットにある ENI（EC2、RDS、Lambda、ALB、Fargate のタスクなど）
  def network_interfaces(ctx, record)
    params = { "Filters" => [{ "Name" => "subnet-id", "Values" => [record["subnet_id"]] }] }
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
        "security_group_ids" => (n["Groups"] || []).map { |g| g["GroupId"] },
      }
    end
  end

  DETAIL_KINDS = {
    "network_interfaces" => [%w[subnet], :network_interfaces],
  }.freeze
end
