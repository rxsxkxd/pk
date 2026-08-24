#!/usr/bin/env bash
# EC2 インスタンスごとに 設定 / ベース OS / AMI / SSM の状態 を JSONL で出力する
#
# API 呼び出しは DescribeInstances と DescribeInstanceInformation（SSM）を 1 回ずつ（ページ分）と、
# 使われている AMI を 100 個ずつまとめた DescribeImages だけ。出力の項目は ../README.md を参照。
set -euo pipefail

for cmd in aws jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd が必要です" >&2; exit 1; }
done

script_dir=$(cd "$(dirname "$0")" && pwd)
patterns_file="$script_dir/../ami-os-patterns.json"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# CLI のエラー文から 操作名・コード・本文 を取り出す（$1: 取り出せないときの操作名, $2: stderr のファイル）
cli_error() {
  jq -nc --arg op "$1" --arg err "$(<"$2")" '
    ($err | capture("\\((?<code>[^)]+)\\) when calling the (?<operation>[A-Za-z]+) operation: (?<message>.*)"))
      // {operation: $op, code: "Unknown", message: $err}
    | {operation, code, message}'
}

# 終了済み（terminated）は除く
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
  --output json >"$work/instances.json"

# AMI は ID 指定だと 1 つでも登録解除済みのものがあると全体がエラーになるので、フィルタで引く
jq -r '[.Reservations[].Instances[].ImageId] | unique | . as $ids
       | range(0; length; 100) | $ids[.:. + 100] | join(",")' "$work/instances.json" |
  while read -r ids; do
    aws ec2 describe-images --include-deprecated --filters "Name=image-id,Values=$ids" --output json </dev/null
  done >"$work/images.json"

# SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける
ssm_error=null
if ! aws ssm describe-instance-information --output json >"$work/ssm.json" 2>"$work/err"; then
  echo '{"InstanceInformationList": []}' >"$work/ssm.json"
  ssm_error=$(cli_error DescribeInstanceInformation "$work/err")
fi

jq -c -n \
  --slurpfile instances "$work/instances.json" \
  --slurpfile images "$work/images.json" \
  --slurpfile ssm "$work/ssm.json" \
  --slurpfile patterns "$patterns_file" \
  --argjson ssm_error "$ssm_error" '
  # CLI の日時（ISO 8601 のタイムゾーン付き、または設定によってはエポック秒）を UTC の秒単位にそろえる
  def utc_iso:
    if . == null then null
    elif type == "number" then floor | todate
    else
      (capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$") // null) as $m
      | if $m == null then .
        else
          ($m.tz | if . == "Z" then 0
                   else (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)
                   end) as $offset
          | ($m.dt + "Z" | fromdateiso8601) - $offset | todate
        end
    end;

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
  | {
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
        else {
          name: $i.Name,
          description: $i.Description,
          owner_id: $i.OwnerId,
          creation_date: $i.CreationDate,
          deprecation_time: $i.DeprecationTime
        }
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
      auto_scaling_group: tag("aws:autoscaling:groupName"),
      launch_template: (
        if $lt_id == null then null
        else {id: $lt_id, version: tag("aws:ec2launchtemplate:version")}
        end
      ),
      ssm: (
        if $s == null then null
        else {
          ping_status: $s.PingStatus,
          agent_version: $s.AgentVersion,
          platform_type: $s.PlatformType,
          last_ping_at: ($s.LastPingDateTime | utc_iso)
        }
        end
      ),
      tags: (.Tags // [] | map(select(.Key != "Name")) | from_entries),
      errors: [$ssm_error | select(. != null)]
    }'
