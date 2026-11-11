# frozen_string_literal: true

# ロードバランサー（ELBv2: ALB・NLB・GWLB）とターゲットグループの棚卸し（Ruby SDK 版の service）。
# 出力の項目は ../../DATA.md を参照。

require "aws-sdk-elasticloadbalancingv2"

module Service
  TOOL = "alb_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def snapshot(ctx, _opts)
    elb = ctx.client(:ElasticLoadBalancingV2)
    lbs = elb.describe_load_balancers.flat_map(&:load_balancers)
    groups = elb.describe_target_groups.flat_map(&:target_groups)

    # タグは 20 件ずつまとめて引く
    arns = lbs.map(&:load_balancer_arn) + groups.map(&:target_group_arn)
    tags_by_arn = arns.each_slice(20).flat_map { |chunk| elb.describe_tags(resource_arns: chunk).tag_descriptions }
                      .to_h { |d| [d.resource_arn, InventoryCommon.tags_object(d.tags)] }

    lb_records = lbs.map do |lb|
      arn = lb.load_balancer_arn
      ctx.record("elbv2_load_balancer", {
        "load_balancer_name" => lb.load_balancer_name,
        "load_balancer_arn" => arn,
        "type" => lb.type,
        "scheme" => lb.scheme,
        "state" => lb.state&.code,
        "dns_name" => lb.dns_name,
        "vpc_id" => lb.vpc_id,
        "availability_zones" => (lb.availability_zones || []).map { |z| { "zone_name" => z.zone_name, "subnet_id" => z.subnet_id } },
        "security_group_ids" => lb.security_groups || [],
        "ip_address_type" => lb.ip_address_type,
        "created_time" => InventoryCommon.utc_iso(lb.created_time),
        "target_group_arns" => groups.select { |g| (g.load_balancer_arns || []).include?(arn) }.map(&:target_group_arn),
        "tags" => tags_by_arn.fetch(arn, {}),
      })
    end
    tg_records = groups.map do |g|
      ctx.record("elbv2_target_group", {
        "target_group_name" => g.target_group_name,
        "target_group_arn" => g.target_group_arn,
        "target_type" => g.target_type,
        "protocol" => g.protocol,
        "port" => g.port,
        "vpc_id" => g.vpc_id,
        "health_check" => {
          "protocol" => g.health_check_protocol,
          "path" => g.health_check_path,
          "port" => g.health_check_port,
          "interval_sec" => g.health_check_interval_seconds,
          "timeout_sec" => g.health_check_timeout_seconds,
          "healthy_threshold" => g.healthy_threshold_count,
          "unhealthy_threshold" => g.unhealthy_threshold_count,
          "matcher" => g.matcher&.http_code,
        },
        "load_balancer_arns" => g.load_balancer_arns || [],
        "tags" => tags_by_arn.fetch(g.target_group_arn, {}),
      })
    end
    lb_records + tg_records
  end

  # リスナーやルールのアクションを要約する
  def action(a)
    forward = a.forward_config&.target_groups
    target_groups = if forward then forward.map(&:target_group_arn)
                    elsif a.target_group_arn then [a.target_group_arn]
                    else []
                    end
    {
      "type" => a.type,
      "target_group_arns" => target_groups,
      "redirect_status" => a.redirect_config&.status_code,
      "fixed_response_status" => a.fixed_response_config&.status_code,
    }
  end

  def condition_values(c)
    return c.values unless c.values.nil? || c.values.empty?

    %i[host_header_config path_pattern_config http_request_method_config source_ip_config].each do |key|
      values = c.public_send(key)&.values
      return values unless values.nil?
    end
    c.values || []
  end

  # リスナーと、その振り分けルール
  def listeners(ctx, record)
    elb = ctx.client(:ElasticLoadBalancingV2)
    ctx.pace { elb.describe_listeners(load_balancer_arn: record["load_balancer_arn"]).flat_map(&:listeners) }.map do |l|
      rules = ctx.pace { elb.describe_rules(listener_arn: l.listener_arn).flat_map(&:rules) }
      {
        "listener_arn" => l.listener_arn,
        "protocol" => l.protocol,
        "port" => l.port,
        "ssl_policy" => l.ssl_policy,
        "certificate_arns" => (l.certificates || []).map(&:certificate_arn),
        "default_actions" => (l.default_actions || []).map { |a| action(a) },
        "rules" => rules.map do |r|
          {
            "priority" => r.priority,
            "is_default" => r.is_default,
            "conditions" => (r.conditions || []).map { |c| { "field" => c.field, "values" => condition_values(c) } },
            "actions" => (r.actions || []).map { |a| action(a) },
          }
        end,
      }
    end
  end

  # ロードバランサーの属性（削除保護・アクセスログ・アイドルタイムアウトなど）
  def attributes(ctx, record)
    ctx.pace do
      ctx.client(:ElasticLoadBalancingV2).describe_load_balancer_attributes(load_balancer_arn: record["load_balancer_arn"]).attributes
    end.to_h { |a| [a.key, a.value] }
  end

  # ターゲットグループに登録されたターゲットと、そのヘルス
  def target_health(ctx, record)
    descriptions = ctx.pace do
      ctx.client(:ElasticLoadBalancingV2).describe_target_health(target_group_arn: record["target_group_arn"]).target_health_descriptions
    end
    descriptions.map do |d|
      {
        "target_id" => d.target&.id,
        "port" => d.target&.port,
        "availability_zone" => d.target&.availability_zone,
        "state" => d.target_health&.state,
        "reason" => d.target_health&.reason,
        "description" => d.target_health&.description,
      }
    end
  end

  DETAIL_KINDS = {
    "listeners" => [%w[elbv2_load_balancer], :listeners],
    "attributes" => [%w[elbv2_load_balancer], :attributes],
    "target_health" => [%w[elbv2_target_group], :target_health],
  }.freeze
end
