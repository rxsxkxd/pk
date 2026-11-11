#!/usr/bin/env bash
# サブネットの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=subnet-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='network_interfaces:subnet'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  aws_json ec2 describe-subnets >"$work/subnets.json"
  aws_json ec2 describe-route-tables >"$work/route-tables.json"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile subnets "$work/subnets.json" \
    --slurpfile route_tables "$work/route-tables.json" "$jq_lib"'
    def route_target:
      .GatewayId // .NatGatewayId // .TransitGatewayId // .VpcPeeringConnectionId // .NetworkInterfaceId
      // .InstanceId // .EgressOnlyInternetGatewayId // .LocalGatewayId // .CarrierGatewayId // .CoreNetworkArn;

    $route_tables[0].RouteTables as $rts
    | $subnets[0].Subnets[]
    | . as $s
    # 明示的に関連付けたルートテーブルが無ければ、VPC のメインのルートテーブルが使われる
    | (first($rts[] | select(any(.Associations[]?; .SubnetId == $s.SubnetId))) // null) as $explicit
    | ($explicit // first($rts[] | select(.VpcId == $s.VpcId and any(.Associations[]?; .Main == true))) // null) as $rt
    | (first($rt.Routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")) // null) as $default_route
    | ($default_route | if . == null then null else route_target end) as $default_target
    | record("subnet"; {
        subnet_id: .SubnetId,
        subnet_arn: .SubnetArn,
        vpc_id: .VpcId,
        cidr_block: .CidrBlock,
        ipv6_cidr_blocks: [.Ipv6CidrBlockAssociationSet[]?.Ipv6CidrBlock],
        availability_zone: .AvailabilityZone,
        availability_zone_id: .AvailabilityZoneId,
        available_ip_address_count: .AvailableIpAddressCount,
        map_public_ip_on_launch: .MapPublicIpOnLaunch,
        default_for_az: .DefaultForAz,
        state: .State,
        route_table_id: $rt.RouteTableId,
        route_table_is_main: ($explicit == null and $rt != null),
        default_route_target: $default_target,
        is_public: (($default_target // "") | startswith("igw-")),
        tags: (.Tags | tags_object)
      })'
}

# サブネットにある ENI（EC2、RDS、Lambda、ALB、Fargate のタスクなど）
detail_network_interfaces() {
  local subnet
  subnet=$(jq -r '.subnet_id' <<<"$1")
  aws_paced ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$subnet" | jq -c '[
    .NetworkInterfaces[]
    | {network_interface_id: .NetworkInterfaceId, interface_type: .InterfaceType, description: .Description,
       requester_id: .RequesterId, requester_managed: .RequesterManaged, status: .Status,
       private_ip_address: .PrivateIpAddress, attachment_instance_id: .Attachment.InstanceId,
       security_group_ids: [.Groups[]?.GroupId]}
  ]'
}

run_main "$@"
