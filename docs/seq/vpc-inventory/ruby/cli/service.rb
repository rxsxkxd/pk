# frozen_string_literal: true

# VPC の棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "vpc_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  ROUTE_TARGET_KEYS = %w[
    GatewayId NatGatewayId TransitGatewayId VpcPeeringConnectionId NetworkInterfaceId
    InstanceId EgressOnlyInternetGatewayId LocalGatewayId CarrierGatewayId CoreNetworkArn
  ].freeze

  module_function

  def first_of(hash, keys) = keys.map { |k| hash[k] }.compact.first

  def snapshot(ctx, _opts)
    vpcs = ctx.call("ec2", "describe_vpcs")["Vpcs"]
    route_tables = ctx.call("ec2", "describe_route_tables")["RouteTables"]
    igws = ctx.call("ec2", "describe_internet_gateways")["InternetGateways"]
    nats = ctx.call("ec2", "describe_nat_gateways")["NatGateways"]
    endpoints = ctx.call("ec2", "describe_vpc_endpoints")["VpcEndpoints"]
    peerings = ctx.call("ec2", "describe_vpc_peering_connections")["VpcPeeringConnections"]
    subnets = ctx.call("ec2", "describe_subnets")["Subnets"]

    vpcs.map do |v|
      vpc = v["VpcId"]
      ctx.record("vpc", {
        "vpc_id" => vpc,
        "cidr_block" => v["CidrBlock"],
        "cidr_blocks" => (v["CidrBlockAssociationSet"] || []).map { |a| a["CidrBlock"] },
        "ipv6_cidr_blocks" => (v["Ipv6CidrBlockAssociationSet"] || []).map { |a| a["Ipv6CidrBlock"] },
        "state" => v["State"],
        "is_default" => v["IsDefault"],
        "dhcp_options_id" => v["DhcpOptionsId"],
        "instance_tenancy" => v["InstanceTenancy"],
        "subnet_count" => subnets.count { |s| s["VpcId"] == vpc },
        "internet_gateway_ids" => igws.select { |g| (g["Attachments"] || []).any? { |a| a["VpcId"] == vpc } }
                                      .map { |g| g["InternetGatewayId"] },
        "nat_gateways" => nats.select { |n| n["VpcId"] == vpc && n["State"] != "deleted" }.map do |n|
          {
            "nat_gateway_id" => n["NatGatewayId"],
            "subnet_id" => n["SubnetId"],
            "state" => n["State"],
            "connectivity_type" => n["ConnectivityType"],
            "public_ip" => n.dig("NatGatewayAddresses", 0, "PublicIp"),
          }
        end,
        "vpc_endpoints" => endpoints.select { |e| e["VpcId"] == vpc }.map do |e|
          { "vpc_endpoint_id" => e["VpcEndpointId"], "service_name" => e["ServiceName"],
            "type" => e["VpcEndpointType"], "state" => e["State"] }
        end,
        "peering_connections" => peerings.select do |p|
          [p.dig("RequesterVpcInfo", "VpcId"), p.dig("AccepterVpcInfo", "VpcId")].include?(vpc) &&
            p.dig("Status", "Code") != "deleted"
        end.map do |p|
          {
            "vpc_peering_connection_id" => p["VpcPeeringConnectionId"],
            "status" => p.dig("Status", "Code"),
            "requester_vpc_id" => p.dig("RequesterVpcInfo", "VpcId"),
            "accepter_vpc_id" => p.dig("AccepterVpcInfo", "VpcId"),
          }
        end,
        "route_tables" => route_tables.select { |rt| rt["VpcId"] == vpc }.map do |rt|
          associations = rt["Associations"] || []
          {
            "route_table_id" => rt["RouteTableId"],
            "main" => associations.any? { |a| a["Main"] == true },
            "subnet_ids" => associations.filter_map { |a| a["SubnetId"] },
            "routes" => (rt["Routes"] || []).map do |r|
              {
                "destination" => first_of(r, %w[DestinationCidrBlock DestinationIpv6CidrBlock DestinationPrefixListId]),
                "target" => first_of(r, ROUTE_TARGET_KEYS),
                "state" => r["State"],
              }
            end,
          }
        end,
        "tags" => InventoryCommon.tags_object(v["Tags"]),
      })
    end
  end

  # VPC に設定したフローログ
  def flow_logs(ctx, record)
    params = { "Filter" => [{ "Name" => "resource-id", "Values" => [record["vpc_id"]] }] }
    ctx.call("ec2", "describe_flow_logs", params)["FlowLogs"].map do |f|
      {
        "flow_log_id" => f["FlowLogId"],
        "traffic_type" => f["TrafficType"],
        "log_destination_type" => f["LogDestinationType"],
        "log_destination" => f["LogDestination"],
        "status" => f["FlowLogStatus"],
        "deliver_logs_status" => f["DeliverLogsStatus"],
      }
    end
  end

  DETAIL_KINDS = {
    "flow_logs" => [%w[vpc], :flow_logs],
  }.freeze
end
