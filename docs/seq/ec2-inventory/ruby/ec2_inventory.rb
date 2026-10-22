#!/usr/bin/env ruby
# frozen_string_literal: true

# EC2 インスタンスごとに 設定 / ベース OS / AMI / SSM の状態 を JSONL で出力する
#
# API 呼び出しは DescribeInstances と DescribeInstanceInformation（SSM）を 1 回ずつ（ページ分）と、
# 使われている AMI を 100 個ずつまとめた DescribeImages だけ。出力の項目は ../README.md を参照。

require "json"
require "time"
require "aws-sdk-ec2"
require "aws-sdk-ssm"

module Ec2Inventory
  PATTERNS_PATH = File.expand_path("../ami-os-patterns.json", __dir__)
  # 終了済み（terminated）は除く
  LIVE_STATES = %w[pending running stopping stopped shutting-down].freeze

  module_function

  def run(ec2: Aws::EC2::Client.new, ssm: Aws::SSM::Client.new, out: $stdout,
          patterns: JSON.parse(File.read(PATTERNS_PATH)))
    instances = ec2.describe_instances(filters: [{ name: "instance-state-name", values: LIVE_STATES }])
                   .flat_map(&:reservations).flat_map(&:instances)
    images = fetch_images(ec2, instances.map(&:image_id).uniq.sort)
    ssm_by_id, ssm_error = fetch_ssm(ssm)

    instances.each do |inst|
      out.puts JSON.generate(record(inst, images[inst.image_id], ssm_by_id[inst.instance_id], ssm_error, patterns))
    end
  end

  # ID 指定だと 1 つでも登録解除済みの AMI があると全体がエラーになるので、フィルタで引く
  def fetch_images(ec2, ids)
    ids.each_slice(100).flat_map do |chunk|
      ec2.describe_images(include_deprecated: true, filters: [{ name: "image-id", values: chunk }]).flat_map(&:images)
    end.to_h { |image| [image.image_id, image] }
  end

  # SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける
  def fetch_ssm(ssm)
    list = ssm.describe_instance_information.flat_map(&:instance_information_list)
    [list.to_h { |info| [info.instance_id, info] }, nil]
  rescue Aws::SSM::Errors::ServiceError => e
    [{}, { "operation" => "DescribeInstanceInformation", "code" => e.code, "message" => e.message }]
  end

  def record(inst, image, ssm, ssm_error, patterns)
    tags = (inst.tags || []).to_h { |t| [t.key, t.value] }
    os, os_source = base_os(inst, image, ssm, patterns)
    lt_id = tags["aws:ec2launchtemplate:id"]
    {
      "instance_id" => inst.instance_id,
      "name" => tags["Name"],
      "state" => inst.state&.name,
      "instance_type" => inst.instance_type,
      "architecture" => inst.architecture,
      "platform_details" => inst.platform_details,
      "base_os" => os,
      "base_os_source" => os_source,
      "image_id" => inst.image_id,
      "image" => image && {
        "name" => image.name,
        "description" => image.description,
        "owner_id" => image.owner_id,
        "creation_date" => image.creation_date,
        "deprecation_time" => image.deprecation_time,
      },
      "launch_time" => utc_iso(inst.launch_time),
      "availability_zone" => inst.placement&.availability_zone,
      "vpc_id" => inst.vpc_id,
      "subnet_id" => inst.subnet_id,
      "private_ip_address" => inst.private_ip_address,
      "public_ip_address" => inst.public_ip_address,
      "security_group_ids" => (inst.security_groups || []).map(&:group_id),
      "iam_instance_profile_arn" => inst.iam_instance_profile&.arn,
      "key_name" => inst.key_name,
      "imds_http_tokens" => inst.metadata_options&.http_tokens,
      "auto_scaling_group" => tags["aws:autoscaling:groupName"],
      "launch_template" => lt_id && { "id" => lt_id, "version" => tags["aws:ec2launchtemplate:version"] },
      "ssm" => ssm && {
        "ping_status" => ssm.ping_status,
        "agent_version" => ssm.agent_version,
        "platform_type" => ssm.platform_type,
        "last_ping_at" => utc_iso(ssm.last_ping_date_time),
      },
      "tags" => tags,
      "errors" => [ssm_error].compact,
    }
  end

  # SSM エージェントの報告 → AMI 名 → PlatformDetails の順で決める
  def base_os(inst, image, ssm, patterns)
    ssm_os = [ssm&.platform_name, ssm&.platform_version].reject { |v| v.nil? || v.empty? }.join(" ")
    return [ssm_os, "ssm"] unless ssm_os.empty?

    ami_os = image&.name && patterns.find { |p| Regexp.new(p["pattern"]).match?(image.name) }&.fetch("os")
    return [ami_os, "ami_name"] if ami_os

    [inst.platform_details, "platform_details"]
  end

  def utc_iso(time) = time&.getutc&.iso8601
end

Ec2Inventory.run if $PROGRAM_NAME == __FILE__
