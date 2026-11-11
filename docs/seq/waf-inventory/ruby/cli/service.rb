# frozen_string_literal: true

# WAF（wafv2）の Web ACL の棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "waf_inventory.rb"
  SNAPSHOT_OPTIONS = { "--scope" => "REGIONAL か CLOUDFRONT。指定しなければ両方" }.freeze
  REGIONAL_RESOURCE_TYPES = %w[APPLICATION_LOAD_BALANCER API_GATEWAY APPSYNC COGNITO_USER_POOL].freeze

  module_function

  # CLOUDFRONT スコープの Web ACL は us-east-1 にある
  def scope_region(ctx, scope) = scope == "CLOUDFRONT" ? "us-east-1" : ctx.aws.region

  # ListWebACLs は NextMarker を自分でたどる
  def list_web_acls(ctx, scope)
    acls = []
    marker = nil
    loop do
      params = { "Scope" => scope }
      params["NextMarker"] = marker if marker
      page = ctx.call("wafv2", "list_web_acls", params, scope_region(ctx, scope))
      acls.concat(page["WebACLs"] || [])
      marker = page["NextMarker"]
      break if marker.nil? || marker.empty?
    end
    acls
  end

  def snapshot(ctx, opts)
    scopes = opts["scope"].empty? ? %w[REGIONAL CLOUDFRONT] : opts["scope"]
    scopes.flat_map do |scope|
      list_web_acls(ctx, scope).map do |acl|
        ctx.record("wafv2_web_acl", {
          "region" => scope == "CLOUDFRONT" ? "global" : ctx.common["region"],
          "scope" => scope,
          "name" => acl["Name"],
          "id" => acl["Id"],
          "arn" => acl["ARN"],
          "description" => acl["Description"],
        })
      end
    end
  end

  # 既定のアクションと、ルールの一覧（優先度・アクション・種類・マネージドルールグループ）
  def rules(ctx, record)
    params = { "Scope" => record["scope"], "Name" => record["name"], "Id" => record["id"] }
    acl = ctx.call("wafv2", "get_web_acl", params, scope_region(ctx, record["scope"]))["WebACL"] || {}
    {
      "default_action" => (acl["DefaultAction"] || {}).keys.first,
      "capacity" => acl["Capacity"],
      "rules" => (acl["Rules"] || []).map do |r|
        statement = r["Statement"] || {}
        managed = statement["ManagedRuleGroupStatement"]
        {
          "name" => r["Name"],
          "priority" => r["Priority"],
          "action" => r["Action"].nil? ? "override:#{(r['OverrideAction'] || {}).keys.first}" : r["Action"].keys.first,
          "statement_type" => statement.keys.first,
          "managed_rule_group" => managed && "#{managed['VendorName']}/#{managed['Name']}",
          "rule_group_arn" => statement.dig("RuleGroupReferenceStatement", "ARN"),
        }
      end,
    }
  end

  # Web ACL を関連付けている先。CLOUDFRONT スコープはディストリビューション、REGIONAL は ALB・API Gateway など
  def resources(ctx, record)
    if record["scope"] == "CLOUDFRONT"
      result = ctx.call("cloudfront", "list_distributions_by_web_acl_id", { "WebACLId" => record["arn"] })
      (result.dig("DistributionList", "Items") || []).map do |d|
        { "resource_type" => "CLOUDFRONT_DISTRIBUTION", "resource_arn" => d["ARN"] }
      end
    else
      REGIONAL_RESOURCE_TYPES.flat_map do |type|
        params = { "WebACLArn" => record["arn"], "ResourceType" => type }
        (ctx.call("wafv2", "list_resources_for_web_acl", params)["ResourceArns"] || []).map do |arn|
          { "resource_type" => type, "resource_arn" => arn }
        end
      end
    end
  end

  # ログの出力先。ログを設定していなければ nil
  def logging(ctx, record)
    config = ctx.call_or_nil(%w[WAFNonexistentItemException], "wafv2", "get_logging_configuration",
                             { "ResourceArn" => record["arn"] }, scope_region(ctx, record["scope"]))
    config && { "log_destinations" => config.dig("LoggingConfiguration", "LogDestinationConfigs") || [] }
  end

  DETAIL_KINDS = {
    "rules" => [%w[wafv2_web_acl], :rules],
    "resources" => [%w[wafv2_web_acl], :resources],
    "logging" => [%w[wafv2_web_acl], :logging],
  }.freeze
end
