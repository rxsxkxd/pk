# frozen_string_literal: true

# EC2 インスタンスの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-ec2"
require "aws-sdk-elasticloadbalancingv2"
require "aws-sdk-ssm"

module Service
  TOOL = "ec2_inventory.rb"
  SNAPSHOT_OPTIONS = { "--filter" => "DescribeInstances のフィルタ。AWS CLI と同じ書き方（例: Name=tag:env,Values=prod）" }.freeze
  # 終了済み（terminated）は除く
  LIVE_STATES = %w[pending running stopping stopped shutting-down].freeze
  PATTERNS = JSON.parse(File.read(File.join(__dir__, "ami-os-patterns.json")))

  module_function

  def parse_filter(text)
    m = text.match(/\AName=([^,]+),Values=(.+)\z/) or abort "--filter の形が違います: #{text}"
    { name: m[1], values: m[2].split(",") }
  end

  def snapshot(ctx, opts)
    ec2 = ctx.client(:EC2)
    filters = [{ name: "instance-state-name", values: LIVE_STATES }] + opts["filter"].map { |f| parse_filter(f) }
    instances = ec2.describe_instances(filters: filters).flat_map(&:reservations).flat_map(&:instances)

    # AMI は ID 指定だと 1 つでも登録解除済みのものがあると全体がエラーになるので、フィルタで 100 個ずつ引く
    images = instances.map(&:image_id).uniq.sort.each_slice(100).flat_map do |chunk|
      ec2.describe_images(include_deprecated: true, filters: [{ name: "image-id", values: chunk }]).flat_map(&:images)
    end.to_h { |image| [image.image_id, image] }

    # SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける
    ssm_by_id = {}
    ssm_errors = []
    begin
      infos = ctx.client(:SSM).describe_instance_information.flat_map(&:instance_information_list)
      ssm_by_id = infos.to_h { |info| [info.instance_id, info] }
    rescue Aws::Errors::ServiceError => e
      ssm_errors = [InventoryCommon.error_entry(e)]
    end

    instances.map do |inst|
      instance_record(ctx, inst, images[inst.image_id], ssm_by_id[inst.instance_id], ssm_errors)
    end
  end

  def instance_record(ctx, inst, image, ssm, errors)
    tags = InventoryCommon.tags_object(inst.tags)
    os, os_source = base_os(inst, image, ssm)
    lt_id = tags["aws:ec2launchtemplate:id"]
    ctx.record("ec2_instance", {
      "instance_id" => inst.instance_id,
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
      "launch_time" => InventoryCommon.utc_iso(inst.launch_time),
      "availability_zone" => inst.placement&.availability_zone,
      "vpc_id" => inst.vpc_id,
      "subnet_id" => inst.subnet_id,
      "private_ip_address" => inst.private_ip_address,
      "public_ip_address" => inst.public_ip_address,
      "security_group_ids" => (inst.security_groups || []).map(&:group_id),
      "iam_instance_profile_arn" => inst.iam_instance_profile&.arn,
      "key_name" => inst.key_name,
      "imds_http_tokens" => inst.metadata_options&.http_tokens,
      "monitoring_state" => inst.monitoring&.state,
      "auto_scaling_group" => tags["aws:autoscaling:groupName"],
      "launch_template" => lt_id && { "id" => lt_id, "version" => tags["aws:ec2launchtemplate:version"] },
      "ssm" => ssm && {
        "ping_status" => ssm.ping_status,
        "agent_version" => ssm.agent_version,
        "platform_type" => ssm.platform_type,
        "last_ping_at" => InventoryCommon.utc_iso(ssm.last_ping_date_time),
      },
      "tags" => tags.reject { |k, _| k == "Name" },
    }, errors)
  end

  # SSM エージェントの報告 → AMI 名 → PlatformDetails の順で決める
  def base_os(inst, image, ssm)
    ssm_os = [ssm&.platform_name, ssm&.platform_version].reject { |v| v.nil? || v.empty? }.join(" ")
    return [ssm_os, "ssm"] unless ssm_os.empty?

    name = image&.name
    hit = name && PATTERNS.find { |p| Regexp.new(p["pattern"]).match?(name) }
    return [hit["os"], "ami_name"] if hit

    [inst.platform_details, "platform_details"]
  end

  # インスタンスに付いている EBS ボリューム
  def volumes(ctx, record)
    iid = record["instance_id"]
    vols = ctx.pace do
      ctx.client(:EC2).describe_volumes(filters: [{ name: "attachment.instance-id", values: [iid] }]).flat_map(&:volumes)
    end
    vols.map do |v|
      a = (v.attachments || []).find { |x| x.instance_id == iid }
      {
        "volume_id" => v.volume_id,
        "device" => a&.device,
        "size_gib" => v.size,
        "volume_type" => v.volume_type,
        "iops" => v.iops,
        "throughput" => v.throughput,
        "encrypted" => v.encrypted,
        "kms_key_id" => v.kms_key_id,
        "delete_on_termination" => a&.delete_on_termination,
        "state" => v.state,
      }
    end
  end

  # どのターゲットグループに登録されているかはわからないので、すべてのターゲットグループを見る（実行ごとに 1 回）
  def target_health(ctx, record)
    elb = ctx.client(:ElasticLoadBalancingV2)
    groups = ctx.cached(:target_groups) do
      ctx.pace { elb.describe_target_groups.flat_map(&:target_groups).map(&:target_group_arn) }
    end
    groups.flat_map do |tg|
      descriptions = ctx.cached([:health, tg]) do
        ctx.pace { elb.describe_target_health(target_group_arn: tg).target_health_descriptions }
      end
      descriptions.select { |d| d.target.id == record["instance_id"] }.map do |d|
        { "target_group_arn" => tg, "port" => d.target.port,
          "state" => d.target_health&.state, "reason" => d.target_health&.reason }
      end
    end
  end

  DETAIL_KINDS = {
    "volumes" => [%w[ec2_instance], :volumes],
    "target_health" => [%w[ec2_instance], :target_health],
  }.freeze
end
