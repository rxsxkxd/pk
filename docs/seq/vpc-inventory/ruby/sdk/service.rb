# frozen_string_literal: true

# VPC の棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-ec2"

module Service
  TOOL = "vpc_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  ROUTE_TARGET_METHODS = %i[
    gateway_id nat_gateway_id transit_gateway_id vpc_peering_connection_id network_interface_id
    instance_id egress_only_internet_gateway_id local_gateway_id carrier_gateway_id core_network_arn
  ].freeze

  module_function

  def first_of(obj, methods) = methods.map { |m| obj.public_send(m) }.compact.first

  def snapshot(ctx, _opts)
    ec2 = ctx.client(:EC2)
    vpcs = ec2.describe_vpcs.flat_map(&:vpcs)
    route_tables = ec2.describe_route_tables.flat_map(&:route_tables)
    igws = ec2.describe_internet_gateways.flat_map(&:internet_gateways)
    nats = ec2.describe_nat_gateways.flat_map(&:nat_gateways)
    endpoints = ec2.describe_vpc_endpoints.flat_map(&:vpc_endpoints)
    peerings = ec2.describe_vpc_peering_connections.flat_map(&:vpc_peering_connections)
    subnets = ec2.describe_subnets.flat_map(&:subnets)

    vpcs.map do |v|
      vpc = v.vpc_id
      ctx.record("vpc", {
        "vpc_id" => vpc,
        "cidr_block" => v.cidr_block,
        "cidr_blocks" => (v.cidr_block_association_set || []).map(&:cidr_block),
        "ipv6_cidr_blocks" => (v.ipv_6_cidr_block_association_set || []).map(&:ipv_6_cidr_block),
        "state" => v.state,
        "is_default" => v.is_default,
        "dhcp_options_id" => v.dhcp_options_id,
        "instance_tenancy" => v.instance_tenancy,
        "subnet_count" => subnets.count { |s| s.vpc_id == vpc },
        "internet_gateway_ids" => igws.select { |g| (g.attachments || []).any? { |a| a.vpc_id == vpc } }
                                      .map(&:internet_gateway_id),
        "nat_gateways" => nats.select { |n| n.vpc_id == vpc && n.state != "deleted" }.map do |n|
          {
            "nat_gateway_id" => n.nat_gateway_id,
            "subnet_id" => n.subnet_id,
            "state" => n.state,
            "connectivity_type" => n.connectivity_type,
            "public_ip" => n.nat_gateway_addresses&.first&.public_ip,
          }
        end,
        "vpc_endpoints" => endpoints.select { |e| e.vpc_id == vpc }.map do |e|
          { "vpc_endpoint_id" => e.vpc_endpoint_id, "service_name" => e.service_name,
            "type" => e.vpc_endpoint_type, "state" => e.state }
        end,
        "peering_connections" => peerings.select do |p|
          [p.requester_vpc_info&.vpc_id, p.accepter_vpc_info&.vpc_id].include?(vpc) && p.status&.code != "deleted"
        end.map do |p|
          {
            "vpc_peering_connection_id" => p.vpc_peering_connection_id,
            "status" => p.status&.code,
            "requester_vpc_id" => p.requester_vpc_info&.vpc_id,
            "accepter_vpc_id" => p.accepter_vpc_info&.vpc_id,
          }
        end,
        "route_tables" => route_tables.select { |rt| rt.vpc_id == vpc }.map do |rt|
          associations = rt.associations || []
          {
            "route_table_id" => rt.route_table_id,
            "main" => associations.any? { |a| a.main == true },
            "subnet_ids" => associations.filter_map(&:subnet_id),
            "routes" => (rt.routes || []).map do |r|
              {
                "destination" => first_of(r, %i[destination_cidr_block destination_ipv_6_cidr_block destination_prefix_list_id]),
                "target" => first_of(r, ROUTE_TARGET_METHODS),
                "state" => r.state,
              }
            end,
          }
        end,
        "tags" => InventoryCommon.tags_object(v.tags),
      })
    end
  end

  # VPC に設定したフローログ
  def flow_logs(ctx, record)
    logs = ctx.pace do
      ctx.client(:EC2).describe_flow_logs(filter: [{ name: "resource-id", values: [record["vpc_id"]] }]).flat_map(&:flow_logs)
    end
    logs.map do |f|
      {
        "flow_log_id" => f.flow_log_id,
        "traffic_type" => f.traffic_type,
        "log_destination_type" => f.log_destination_type,
        "log_destination" => f.log_destination,
        "status" => f.flow_log_status,
        "deliver_logs_status" => f.deliver_logs_status,
      }
    end
  end

  DETAIL_KINDS = {
    "flow_logs" => [%w[vpc], :flow_logs],
  }.freeze
end
