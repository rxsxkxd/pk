# frozen_string_literal: true

# EC2 インスタンスの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "ec2_inventory.rb"
  SNAPSHOT_OPTIONS = { "--filter" => "DescribeInstances のフィルタ。AWS CLI と同じ書き方（例: Name=tag:env,Values=prod）" }.freeze
  # 終了済み（terminated）は除く
  LIVE_STATES = %w[pending running stopping stopped shutting-down].freeze
  PATTERNS = JSON.parse(File.read(File.join(__dir__, "ami-os-patterns.json")))

  module_function

  def parse_filter(text)
    m = text.match(/\AName=([^,]+),Values=(.+)\z/) or abort "--filter の形が違います: #{text}"
    { "Name" => m[1], "Values" => m[2].split(",") }
  end

  def snapshot(ctx, opts)
    filters = [{ "Name" => "instance-state-name", "Values" => LIVE_STATES }] + opts["filter"].map { |f| parse_filter(f) }
    instances = ctx.call("ec2", "describe_instances", { "Filters" => filters })["Reservations"].flat_map { |r| r["Instances"] }

    # AMI は ID 指定だと 1 つでも登録解除済みのものがあると全体がエラーになるので、フィルタで 100 個ずつ引く
    images = instances.map { |i| i["ImageId"] }.uniq.sort.each_slice(100).flat_map do |chunk|
      ctx.call("ec2", "describe_images",
               { "IncludeDeprecated" => true, "Filters" => [{ "Name" => "image-id", "Values" => chunk }] })["Images"]
    end.to_h { |image| [image["ImageId"], image] }

    # SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける
    ssm_by_id = {}
    ssm_errors = []
    begin
      infos = ctx.call("ssm", "describe_instance_information")["InstanceInformationList"]
      ssm_by_id = infos.to_h { |info| [info["InstanceId"], info] }
    rescue InventoryCommon::AwsError => e
      ssm_errors = [InventoryCommon.error_entry(e)]
    end

    instances.map do |inst|
      instance_record(ctx, inst, images[inst["ImageId"]], ssm_by_id[inst["InstanceId"]], ssm_errors)
    end
  end

  def instance_record(ctx, inst, image, ssm, errors)
    tags = InventoryCommon.tags_object(inst["Tags"])
    os, os_source = base_os(inst, image, ssm)
    lt_id = tags["aws:ec2launchtemplate:id"]
    ctx.record("ec2_instance", {
      "instance_id" => inst["InstanceId"],
      "state" => inst.dig("State", "Name"),
      "instance_type" => inst["InstanceType"],
      "architecture" => inst["Architecture"],
      "platform_details" => inst["PlatformDetails"],
      "base_os" => os,
      "base_os_source" => os_source,
      "image_id" => inst["ImageId"],
      "image" => image && {
        "name" => image["Name"],
        "description" => image["Description"],
        "owner_id" => image["OwnerId"],
        "creation_date" => image["CreationDate"],
        "deprecation_time" => image["DeprecationTime"],
      },
      "launch_time" => InventoryCommon.utc_iso(inst["LaunchTime"]),
      "availability_zone" => inst.dig("Placement", "AvailabilityZone"),
      "vpc_id" => inst["VpcId"],
      "subnet_id" => inst["SubnetId"],
      "private_ip_address" => inst["PrivateIpAddress"],
      "public_ip_address" => inst["PublicIpAddress"],
      "security_group_ids" => (inst["SecurityGroups"] || []).map { |sg| sg["GroupId"] },
      "iam_instance_profile_arn" => inst.dig("IamInstanceProfile", "Arn"),
      "key_name" => inst["KeyName"],
      "imds_http_tokens" => inst.dig("MetadataOptions", "HttpTokens"),
      "monitoring_state" => inst.dig("Monitoring", "State"),
      "auto_scaling_group" => tags["aws:autoscaling:groupName"],
      "launch_template" => lt_id && { "id" => lt_id, "version" => tags["aws:ec2launchtemplate:version"] },
      "ssm" => ssm && {
        "ping_status" => ssm["PingStatus"],
        "agent_version" => ssm["AgentVersion"],
        "platform_type" => ssm["PlatformType"],
        "last_ping_at" => InventoryCommon.utc_iso(ssm["LastPingDateTime"]),
      },
      "tags" => tags.reject { |k, _| k == "Name" },
    }, errors)
  end

  # SSM エージェントの報告 → AMI 名 → PlatformDetails の順で決める
  def base_os(inst, image, ssm)
    ssm_os = [ssm&.dig("PlatformName"), ssm&.dig("PlatformVersion")].reject { |v| v.nil? || v.empty? }.join(" ")
    return [ssm_os, "ssm"] unless ssm_os.empty?

    name = image&.dig("Name")
    hit = name && PATTERNS.find { |p| Regexp.new(p["pattern"]).match?(name) }
    return [hit["os"], "ami_name"] if hit

    [inst["PlatformDetails"], "platform_details"]
  end

  # インスタンスに付いている EBS ボリューム
  def volumes(ctx, record)
    iid = record["instance_id"]
    params = { "Filters" => [{ "Name" => "attachment.instance-id", "Values" => [iid] }] }
    ctx.call("ec2", "describe_volumes", params)["Volumes"].map do |v|
      a = (v["Attachments"] || []).find { |x| x["InstanceId"] == iid } || {}
      {
        "volume_id" => v["VolumeId"],
        "device" => a["Device"],
        "size_gib" => v["Size"],
        "volume_type" => v["VolumeType"],
        "iops" => v["Iops"],
        "throughput" => v["Throughput"],
        "encrypted" => v["Encrypted"],
        "kms_key_id" => v["KmsKeyId"],
        "delete_on_termination" => a["DeleteOnTermination"],
        "state" => v["State"],
      }
    end
  end

  # どのターゲットグループに登録されているかはわからないので、すべてのターゲットグループを見る（実行ごとに 1 回）
  def target_health(ctx, record)
    groups = ctx.cached(:target_groups) do
      ctx.call("elbv2", "describe_target_groups")["TargetGroups"].map { |g| g["TargetGroupArn"] }
    end
    groups.flat_map do |tg|
      descriptions = ctx.cached([:health, tg]) do
        ctx.call("elbv2", "describe_target_health", { "TargetGroupArn" => tg })["TargetHealthDescriptions"]
      end
      descriptions.select { |d| d.dig("Target", "Id") == record["instance_id"] }.map do |d|
        { "target_group_arn" => tg, "port" => d.dig("Target", "Port"),
          "state" => d.dig("TargetHealth", "State"), "reason" => d.dig("TargetHealth", "Reason") }
      end
    end
  end

  DETAIL_KINDS = {
    "volumes" => [%w[ec2_instance], :volumes],
    "target_health" => [%w[ec2_instance], :target_health],
  }.freeze
end
