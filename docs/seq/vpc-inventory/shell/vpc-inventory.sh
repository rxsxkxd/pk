#!/usr/bin/env bash
# VPC の棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=vpc-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='flow_logs:vpc'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  aws_json ec2 describe-vpcs >"$work/vpcs.json"
  aws_json ec2 describe-route-tables >"$work/route-tables.json"
  aws_json ec2 describe-internet-gateways >"$work/igws.json"
  aws_json ec2 describe-nat-gateways >"$work/nats.json"
  aws_json ec2 describe-vpc-endpoints >"$work/endpoints.json"
  aws_json ec2 describe-vpc-peering-connections >"$work/peerings.json"
  aws_json ec2 describe-subnets >"$work/subnets.json"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile vpcs "$work/vpcs.json" \
    --slurpfile route_tables "$work/route-tables.json" \
    --slurpfile igws "$work/igws.json" \
    --slurpfile nats "$work/nats.json" \
    --slurpfile endpoints "$work/endpoints.json" \
    --slurpfile peerings "$work/peerings.json" \
    --slurpfile subnets "$work/subnets.json" "$jq_lib"'
    def route_target:
      .GatewayId // .NatGatewayId // .TransitGatewayId // .VpcPeeringConnectionId // .NetworkInterfaceId
      // .InstanceId // .EgressOnlyInternetGatewayId // .LocalGatewayId // .CarrierGatewayId // .CoreNetworkArn;

    $vpcs[0].Vpcs[]
    | .VpcId as $vpc
    | record("vpc"; {
        vpc_id: $vpc,
        cidr_block: .CidrBlock,
        cidr_blocks: [.CidrBlockAssociationSet[]?.CidrBlock],
        ipv6_cidr_blocks: [.Ipv6CidrBlockAssociationSet[]?.Ipv6CidrBlock],
        state: .State,
        is_default: .IsDefault,
        dhcp_options_id: .DhcpOptionsId,
        instance_tenancy: .InstanceTenancy,
        subnet_count: ([$subnets[0].Subnets[] | select(.VpcId == $vpc)] | length),
        internet_gateway_ids: [$igws[0].InternetGateways[] | select(any(.Attachments[]?; .VpcId == $vpc)) | .InternetGatewayId],
        nat_gateways: [
          $nats[0].NatGateways[] | select(.VpcId == $vpc and .State != "deleted")
          | {nat_gateway_id: .NatGatewayId, subnet_id: .SubnetId, state: .State,
             connectivity_type: .ConnectivityType, public_ip: .NatGatewayAddresses[0]?.PublicIp}
        ],
        vpc_endpoints: [
          $endpoints[0].VpcEndpoints[] | select(.VpcId == $vpc)
          | {vpc_endpoint_id: .VpcEndpointId, service_name: .ServiceName, type: .VpcEndpointType, state: .State}
        ],
        peering_connections: [
          $peerings[0].VpcPeeringConnections[]
          | select((.RequesterVpcInfo.VpcId == $vpc or .AccepterVpcInfo.VpcId == $vpc) and .Status.Code != "deleted")
          | {vpc_peering_connection_id: .VpcPeeringConnectionId, status: .Status.Code,
             requester_vpc_id: .RequesterVpcInfo.VpcId, accepter_vpc_id: .AccepterVpcInfo.VpcId}
        ],
        route_tables: [
          $route_tables[0].RouteTables[] | select(.VpcId == $vpc)
          | {
              route_table_id: .RouteTableId,
              main: any(.Associations[]?; .Main == true),
              subnet_ids: [.Associations[]? | select(.SubnetId != null) | .SubnetId],
              routes: [
                .Routes[]?
                | {destination: (.DestinationCidrBlock // .DestinationIpv6CidrBlock // .DestinationPrefixListId),
                   target: route_target, state: .State}
              ]
            }
        ],
        tags: (.Tags | tags_object)
      })'
}

# VPC に設定したフローログ
detail_flow_logs() {
  local vpc
  vpc=$(jq -r '.vpc_id' <<<"$1")
  aws_paced ec2 describe-flow-logs --filter "Name=resource-id,Values=$vpc" | jq -c '[
    .FlowLogs[]
    | {flow_log_id: .FlowLogId, traffic_type: .TrafficType, log_destination_type: .LogDestinationType,
       log_destination: .LogDestination, status: .FlowLogStatus, deliver_logs_status: .DeliverLogsStatus}
  ]'
}

run_main "$@"
