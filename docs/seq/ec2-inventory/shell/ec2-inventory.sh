#!/usr/bin/env bash
# EC2 インスタンスの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=ec2-inventory.sh
SNAPSHOT_USAGE='[--filter Name=...,Values=...]...'
DETAIL_KINDS='volumes:ec2_instance target_health:ec2_instance'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  local filters=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --filter) filters+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done

  # 終了済み（terminated）は除く。--filter はそのまま CLI の --filters に渡す
  aws_json ec2 describe-instances \
    --filters Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    ${filters[@]+"${filters[@]}"} >"$work/instances.json"

  # AMI は ID 指定だと 1 つでも登録解除済みのものがあると全体がエラーになるので、フィルタで 100 個ずつ引く
  jq '[.Reservations[].Instances[].ImageId] | unique' "$work/instances.json" | chunks 100 | tr ' ' ',' |
    while read -r ids; do
      aws_json ec2 describe-images --include-deprecated --filters "Name=image-id,Values=$ids"
    done >"$work/images.json"

  # SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける
  local ssm_error=null
  if ! aws_json ssm describe-instance-information >"$work/ssm.json" 2>"$work/err"; then
    echo '{"InstanceInformationList": []}' >"$work/ssm.json"
    ssm_error=$(cli_error DescribeInstanceInformation "$work/err")
  fi

  jq -c -n \
    --argjson common "$common" \
    --argjson ssm_error "$ssm_error" \
    --slurpfile instances "$work/instances.json" \
    --slurpfile images "$work/images.json" \
    --slurpfile ssm "$work/ssm.json" \
    --slurpfile patterns "$lib_dir/ami-os-patterns.json" "$jq_lib"'
    def tag($k): first(.Tags[]? | select(.Key == $k) | .Value) // null;

    def os_from_ami_name($name):
      if $name == null then null
      else first($patterns[0][] | select(.pattern as $p | $name | test($p)) | .os) // null
      end;

    ([$images[].Images[]] | map({key: .ImageId, value: .}) | from_entries) as $image_by_id
    | ($ssm[0].InstanceInformationList | map({key: .InstanceId, value: .}) | from_entries) as $ssm_by_id
    | $instances[0].Reservations[].Instances[]
    | $image_by_id[.ImageId] as $i
    | $ssm_by_id[.InstanceId] as $s
    | ([$s.PlatformName, $s.PlatformVersion] | map(select(. != null and . != "")) | join(" ")) as $ssm_os
    | os_from_ami_name($i.Name) as $ami_os
    | (if $ssm_os != "" then [$ssm_os, "ssm"]
       elif $ami_os != null then [$ami_os, "ami_name"]
       else [.PlatformDetails, "platform_details"]
       end) as [$os, $os_source]
    | tag("aws:ec2launchtemplate:id") as $lt_id
    | record("ec2_instance"; {
        instance_id: .InstanceId,
        state: .State.Name,
        instance_type: .InstanceType,
        architecture: .Architecture,
        platform_details: .PlatformDetails,
        base_os: $os,
        base_os_source: $os_source,
        image_id: .ImageId,
        image: (
          if $i == null then null
          else {name: $i.Name, description: $i.Description, owner_id: $i.OwnerId,
                creation_date: $i.CreationDate, deprecation_time: $i.DeprecationTime}
          end
        ),
        launch_time: (.LaunchTime | utc_iso),
        availability_zone: .Placement.AvailabilityZone,
        vpc_id: .VpcId,
        subnet_id: .SubnetId,
        private_ip_address: .PrivateIpAddress,
        public_ip_address: .PublicIpAddress,
        security_group_ids: [.SecurityGroups[]?.GroupId],
        iam_instance_profile_arn: .IamInstanceProfile.Arn,
        key_name: .KeyName,
        imds_http_tokens: .MetadataOptions.HttpTokens,
        monitoring_state: .Monitoring.State,
        auto_scaling_group: tag("aws:autoscaling:groupName"),
        launch_template: (if $lt_id == null then null else {id: $lt_id, version: tag("aws:ec2launchtemplate:version")} end),
        ssm: (
          if $s == null then null
          else {ping_status: $s.PingStatus, agent_version: $s.AgentVersion,
                platform_type: $s.PlatformType, last_ping_at: ($s.LastPingDateTime | utc_iso)}
          end
        ),
        tags: (.Tags | tags_object | del(.Name))
      }; [$ssm_error | select(. != null)])'
}

# インスタンスに付いている EBS ボリューム
detail_volumes() {
  local id
  id=$(jq -r '.instance_id' <<<"$1")
  aws_paced ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$id" |
    jq -c --arg id "$id" '[
      .Volumes[]
      | (first(.Attachments[]? | select(.InstanceId == $id)) // {}) as $a
      | {
          volume_id: .VolumeId,
          device: $a.Device,
          size_gib: .Size,
          volume_type: .VolumeType,
          iops: .Iops,
          throughput: .Throughput,
          encrypted: .Encrypted,
          kms_key_id: .KmsKeyId,
          delete_on_termination: $a.DeleteOnTermination,
          state: .State
        }
    ]'
}

all_target_groups() { aws_paced elbv2 describe-target-groups | jq -c '[.TargetGroups[].TargetGroupArn]'; }
target_health_of() { aws_paced elbv2 describe-target-health --target-group-arn "$1"; }

# どのターゲットグループに登録されているかはわからないので、すべてのターゲットグループを見る（実行ごとに 1 回）
detail_target_health() {
  local id tgs tg
  id=$(jq -r '.instance_id' <<<"$1")
  tgs=$(cached target-groups all_target_groups) || return 1
  for tg in $(jq -r '.[]' <<<"$tgs"); do
    cached "health-$tg" target_health_of "$tg" |
      jq -c --arg tg "$tg" '.TargetHealthDescriptions[]
        | {target_group_arn: $tg, target_id: .Target.Id, port: .Target.Port,
           state: .TargetHealth.State, reason: .TargetHealth.Reason}' || exit 1
  done | jq -s -c --arg id "$id" 'map(select(.target_id == $id) | del(.target_id))'
}

run_main "$@"
