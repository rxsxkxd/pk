# frozen_string_literal: true

# CloudFront ディストリビューションの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-cloudfront"

module Service
  TOOL = "cloudfront_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def origin_type(o)
    return "vpc" if o.respond_to?(:vpc_origin_config) && !o.vpc_origin_config.nil?
    return "s3" unless o.s3_origin_config.nil?

    "custom"
  end

  def snapshot(ctx, _opts)
    # CloudFront はリージョンをまたぐサービスなので、region は global にする
    items = ctx.client(:CloudFront).list_distributions.flat_map { |page| page.distribution_list&.items || [] }
    items.map do |d|
      cert = d.viewer_certificate
      dcb = d.default_cache_behavior
      ctx.record("cloudfront_distribution", {
        "region" => "global",
        "distribution_id" => d.id,
        "arn" => d.arn,
        "domain_name" => d.domain_name,
        "aliases" => d.aliases&.items || [],
        "status" => d.status,
        "enabled" => d.enabled,
        "comment" => d.comment,
        "price_class" => d.price_class,
        "http_version" => d.http_version,
        "is_ipv6_enabled" => d.is_ipv6_enabled,
        "web_acl_id" => d.web_acl_id,
        "staging" => d.staging,
        "viewer_certificate" => {
          "acm_certificate_arn" => cert&.acm_certificate_arn,
          "cloudfront_default_certificate" => cert&.cloud_front_default_certificate,
          "minimum_protocol_version" => cert&.minimum_protocol_version,
          "ssl_support_method" => cert&.ssl_support_method,
        },
        "origins" => (d.origins&.items || []).map do |o|
          {
            "id" => o.id,
            "domain_name" => o.domain_name,
            "origin_path" => o.origin_path,
            "origin_type" => origin_type(o),
            "origin_access_control_id" => o.origin_access_control_id,
            "origin_protocol_policy" => o.custom_origin_config&.origin_protocol_policy,
          }
        end,
        "default_cache_behavior" => {
          "target_origin_id" => dcb&.target_origin_id,
          "viewer_protocol_policy" => dcb&.viewer_protocol_policy,
          "cache_policy_id" => dcb&.cache_policy_id,
          "origin_request_policy_id" => dcb&.origin_request_policy_id,
          "function_count" => dcb&.function_associations&.quantity || 0,
          "lambda_function_count" => dcb&.lambda_function_associations&.quantity || 0,
        },
        "cache_behavior_count" => d.cache_behaviors&.quantity || 0,
        "geo_restriction" => d.restrictions&.geo_restriction&.restriction_type,
        "last_modified_time" => InventoryCommon.utc_iso(d.last_modified_time),
      })
    end
  end

  # 一覧に入っていない設定（既定のルートオブジェクト・アクセスログ・エラーページなど）
  def config(ctx, record)
    c = ctx.pace { ctx.client(:CloudFront).get_distribution_config(id: record["distribution_id"]).distribution_config }
    {
      "default_root_object" => c&.default_root_object,
      "logging_enabled" => c&.logging&.enabled,
      "logging_bucket" => c&.logging&.bucket,
      "logging_prefix" => c&.logging&.prefix,
      "custom_error_response_count" => c&.custom_error_responses&.quantity || 0,
      "continuous_deployment_policy_id" => c&.continuous_deployment_policy_id,
    }
  end

  def tags(ctx, record)
    InventoryCommon.tags_object(ctx.pace { ctx.client(:CloudFront).list_tags_for_resource(resource: record["arn"]).tags&.items })
  end

  DETAIL_KINDS = {
    "config" => [%w[cloudfront_distribution], :config],
    "tags" => [%w[cloudfront_distribution], :tags],
  }.freeze
end
