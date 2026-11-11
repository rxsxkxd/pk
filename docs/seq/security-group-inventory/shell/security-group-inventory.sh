#!/usr/bin/env bash
# セキュリティグループの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=security-group-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='network_interfaces:security_group'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  aws_json ec2 describe-security-groups >"$work/groups.json"
  # どの ENI がどの SG を使っているかを数えるため、リージョンの ENI をまとめて引く
  aws_json ec2 describe-network-interfaces >"$work/enis.json"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile groups "$work/groups.json" \
    --slurpfile enis "$work/enis.json" "$jq_lib"'
    # 許可のまとまり（IpPermissions）を、許可元・許可先 1 つにつき 1 行のルールに展開する
    def rules:
      [
        .[]? as $p
        | (
            [$p.IpRanges[]? | {source: .CidrIp, source_type: "cidr", description: .Description}]
            + [$p.Ipv6Ranges[]? | {source: .CidrIpv6, source_type: "ipv6_cidr", description: .Description}]
            + [$p.PrefixListIds[]? | {source: .PrefixListId, source_type: "prefix_list", description: .Description}]
            + [$p.UserIdGroupPairs[]? | {source: .GroupId, source_type: "security_group", description: .Description}]
          )[]
        | {protocol: $p.IpProtocol, from_port: $p.FromPort, to_port: $p.ToPort} + .
      ];

    $groups[0].SecurityGroups as $all
    | $enis[0].NetworkInterfaces as $enis
    | $all[]
    | .GroupId as $id
    | (.IpPermissions | rules) as $inbound
    | [$enis[] | select(any(.Groups[]?; .GroupId == $id))] as $users
    | record("security_group"; {
        group_id: $id,
        group_name: .GroupName,
        description: .Description,
        vpc_id: .VpcId,
        inbound_rules: $inbound,
        outbound_rules: (.IpPermissionsEgress | rules),
        open_to_world: any($inbound[]; .source == "0.0.0.0/0" or .source == "::/0"),
        referenced_by: [
          $all[] | select(.GroupId != $id)
          | select(any((.IpPermissions + .IpPermissionsEgress)[]?.UserIdGroupPairs[]?; .GroupId == $id))
          | .GroupId
        ],
        network_interface_count: ($users | length),
        interface_types: ([$users[].InterfaceType] | unique),
        instance_ids: ([$users[].Attachment.InstanceId | select(. != null)] | unique),
        tags: (.Tags | tags_object)
      })'
}

# SG を使っている ENI
detail_network_interfaces() {
  local group
  group=$(jq -r '.group_id' <<<"$1")
  aws_paced ec2 describe-network-interfaces --filters "Name=group-id,Values=$group" | jq -c '[
    .NetworkInterfaces[]
    | {network_interface_id: .NetworkInterfaceId, interface_type: .InterfaceType, description: .Description,
       requester_id: .RequesterId, requester_managed: .RequesterManaged, status: .Status,
       private_ip_address: .PrivateIpAddress, attachment_instance_id: .Attachment.InstanceId,
       subnet_id: .SubnetId}
  ]'
}

run_main "$@"
