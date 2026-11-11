# frozen_string_literal: true

# CloudFront ディストリビューションの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "cloudfront_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def origin_type(o)
    return "vpc" unless o["VpcOriginConfig"].nil?
    return "s3" unless o["S3OriginConfig"].nil?

    "custom"
  end

  def snapshot(ctx, _opts)
    # CloudFront はリージョンをまたぐサービスなので、region は global にする
    (ctx.call("cloudfront", "list_distributions").dig("DistributionList", "Items") || []).map do |d|
      cert = d["ViewerCertificate"] || {}
      dcb = d["DefaultCacheBehavior"] || {}
      ctx.record("cloudfront_distribution", {
        "region" => "global",
        "distribution_id" => d["Id"],
        "arn" => d["ARN"],
        "domain_name" => d["DomainName"],
        "aliases" => d.dig("Aliases", "Items") || [],
        "status" => d["Status"],
        "enabled" => d["Enabled"],
        "comment" => d["Comment"],
        "price_class" => d["PriceClass"],
        "http_version" => d["HttpVersion"],
        "is_ipv6_enabled" => d["IsIPV6Enabled"],
        "web_acl_id" => d["WebACLId"],
        "staging" => d["Staging"],
        "viewer_certificate" => {
          "acm_certificate_arn" => cert["ACMCertificateArn"],
          "cloudfront_default_certificate" => cert["CloudFrontDefaultCertificate"],
          "minimum_protocol_version" => cert["MinimumProtocolVersion"],
          "ssl_support_method" => cert["SSLSupportMethod"],
        },
        "origins" => (d.dig("Origins", "Items") || []).map do |o|
          {
            "id" => o["Id"],
            "domain_name" => o["DomainName"],
            "origin_path" => o["OriginPath"],
            "origin_type" => origin_type(o),
            "origin_access_control_id" => o["OriginAccessControlId"],
            "origin_protocol_policy" => o.dig("CustomOriginConfig", "OriginProtocolPolicy"),
          }
        end,
        "default_cache_behavior" => {
          "target_origin_id" => dcb["TargetOriginId"],
          "viewer_protocol_policy" => dcb["ViewerProtocolPolicy"],
          "cache_policy_id" => dcb["CachePolicyId"],
          "origin_request_policy_id" => dcb["OriginRequestPolicyId"],
          "function_count" => dcb.dig("FunctionAssociations", "Quantity") || 0,
          "lambda_function_count" => dcb.dig("LambdaFunctionAssociations", "Quantity") || 0,
        },
        "cache_behavior_count" => d.dig("CacheBehaviors", "Quantity") || 0,
        "geo_restriction" => d.dig("Restrictions", "GeoRestriction", "RestrictionType"),
        "last_modified_time" => InventoryCommon.utc_iso(d["LastModifiedTime"]),
      })
    end
  end

  # 一覧に入っていない設定（既定のルートオブジェクト・アクセスログ・エラーページなど）
  def config(ctx, record)
    c = ctx.call("cloudfront", "get_distribution_config", { "Id" => record["distribution_id"] })["DistributionConfig"] || {}
    {
      "default_root_object" => c["DefaultRootObject"],
      "logging_enabled" => c.dig("Logging", "Enabled"),
      "logging_bucket" => c.dig("Logging", "Bucket"),
      "logging_prefix" => c.dig("Logging", "Prefix"),
      "custom_error_response_count" => c.dig("CustomErrorResponses", "Quantity") || 0,
      "continuous_deployment_policy_id" => c["ContinuousDeploymentPolicyId"],
    }
  end

  def tags(ctx, record)
    result = ctx.call("cloudfront", "list_tags_for_resource", { "Resource" => record["arn"] })
    InventoryCommon.tags_object(result.dig("Tags", "Items"))
  end

  DETAIL_KINDS = {
    "config" => [%w[cloudfront_distribution], :config],
    "tags" => [%w[cloudfront_distribution], :tags],
  }.freeze
end
