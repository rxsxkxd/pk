# frozen_string_literal: true

# ロードバランサー（ELBv2: ALB・NLB・GWLB）とターゲットグループの棚卸し（Ruby CLI 版の service）。
# 出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "alb_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def snapshot(ctx, _opts)
    lbs = ctx.call("elbv2", "describe_load_balancers")["LoadBalancers"]
    groups = ctx.call("elbv2", "describe_target_groups")["TargetGroups"]

    # タグは 20 件ずつまとめて引く
    arns = lbs.map { |lb| lb["LoadBalancerArn"] } + groups.map { |g| g["TargetGroupArn"] }
    tags_by_arn = arns.each_slice(20).flat_map do |chunk|
      ctx.call("elbv2", "describe_tags", { "ResourceArns" => chunk })["TagDescriptions"]
    end.to_h { |d| [d["ResourceArn"], InventoryCommon.tags_object(d["Tags"])] }

    lb_records = lbs.map do |lb|
      arn = lb["LoadBalancerArn"]
      ctx.record("elbv2_load_balancer", {
        "load_balancer_name" => lb["LoadBalancerName"],
        "load_balancer_arn" => arn,
        "type" => lb["Type"],
        "scheme" => lb["Scheme"],
        "state" => lb.dig("State", "Code"),
        "dns_name" => lb["DNSName"],
        "vpc_id" => lb["VpcId"],
        "availability_zones" => (lb["AvailabilityZones"] || []).map { |z| { "zone_name" => z["ZoneName"], "subnet_id" => z["SubnetId"] } },
        "security_group_ids" => lb["SecurityGroups"] || [],
        "ip_address_type" => lb["IpAddressType"],
        "created_time" => InventoryCommon.utc_iso(lb["CreatedTime"]),
        "target_group_arns" => groups.select { |g| (g["LoadBalancerArns"] || []).include?(arn) }.map { |g| g["TargetGroupArn"] },
        "tags" => tags_by_arn.fetch(arn, {}),
      })
    end
    tg_records = groups.map do |g|
      ctx.record("elbv2_target_group", {
        "target_group_name" => g["TargetGroupName"],
        "target_group_arn" => g["TargetGroupArn"],
        "target_type" => g["TargetType"],
        "protocol" => g["Protocol"],
        "port" => g["Port"],
        "vpc_id" => g["VpcId"],
        "health_check" => {
          "protocol" => g["HealthCheckProtocol"],
          "path" => g["HealthCheckPath"],
          "port" => g["HealthCheckPort"],
          "interval_sec" => g["HealthCheckIntervalSeconds"],
          "timeout_sec" => g["HealthCheckTimeoutSeconds"],
          "healthy_threshold" => g["HealthyThresholdCount"],
          "unhealthy_threshold" => g["UnhealthyThresholdCount"],
          "matcher" => g.dig("Matcher", "HttpCode"),
        },
        "load_balancer_arns" => g["LoadBalancerArns"] || [],
        "tags" => tags_by_arn.fetch(g["TargetGroupArn"], {}),
      })
    end
    lb_records + tg_records
  end

  # リスナーやルールのアクションを要約する
  def action(a)
    forward = a.dig("ForwardConfig", "TargetGroups")
    target_groups = if forward then forward.map { |t| t["TargetGroupArn"] }
                    elsif a["TargetGroupArn"] then [a["TargetGroupArn"]]
                    else []
                    end
    {
      "type" => a["Type"],
      "target_group_arns" => target_groups,
      "redirect_status" => a.dig("RedirectConfig", "StatusCode"),
      "fixed_response_status" => a.dig("FixedResponseConfig", "StatusCode"),
    }
  end

  def condition_values(c)
    return c["Values"] unless c["Values"].nil?

    %w[HostHeaderConfig PathPatternConfig HttpRequestMethodConfig SourceIpConfig].each do |key|
      values = c.dig(key, "Values")
      return values unless values.nil?
    end
    []
  end

  # リスナーと、その振り分けルール
  def listeners(ctx, record)
    ctx.call("elbv2", "describe_listeners", { "LoadBalancerArn" => record["load_balancer_arn"] })["Listeners"].map do |l|
      rules = ctx.call("elbv2", "describe_rules", { "ListenerArn" => l["ListenerArn"] })["Rules"]
      {
        "listener_arn" => l["ListenerArn"],
        "protocol" => l["Protocol"],
        "port" => l["Port"],
        "ssl_policy" => l["SslPolicy"],
        "certificate_arns" => (l["Certificates"] || []).map { |c| c["CertificateArn"] },
        "default_actions" => (l["DefaultActions"] || []).map { |a| action(a) },
        "rules" => rules.map do |r|
          {
            "priority" => r["Priority"],
            "is_default" => r["IsDefault"],
            "conditions" => (r["Conditions"] || []).map { |c| { "field" => c["Field"], "values" => condition_values(c) } },
            "actions" => (r["Actions"] || []).map { |a| action(a) },
          }
        end,
      }
    end
  end

  # ロードバランサーの属性（削除保護・アクセスログ・アイドルタイムアウトなど）
  def attributes(ctx, record)
    ctx.call("elbv2", "describe_load_balancer_attributes", { "LoadBalancerArn" => record["load_balancer_arn"] })["Attributes"]
       .to_h { |a| [a["Key"], a["Value"]] }
  end

  # ターゲットグループに登録されたターゲットと、そのヘルス
  def target_health(ctx, record)
    ctx.call("elbv2", "describe_target_health", { "TargetGroupArn" => record["target_group_arn"] })["TargetHealthDescriptions"].map do |d|
      {
        "target_id" => d.dig("Target", "Id"),
        "port" => d.dig("Target", "Port"),
        "availability_zone" => d.dig("Target", "AvailabilityZone"),
        "state" => d.dig("TargetHealth", "State"),
        "reason" => d.dig("TargetHealth", "Reason"),
        "description" => d.dig("TargetHealth", "Description"),
      }
    end
  end

  DETAIL_KINDS = {
    "listeners" => [%w[elbv2_load_balancer], :listeners],
    "attributes" => [%w[elbv2_load_balancer], :attributes],
    "target_health" => [%w[elbv2_target_group], :target_health],
  }.freeze
end
