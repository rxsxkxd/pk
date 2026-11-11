# frozen_string_literal: true

# WAF（wafv2）の Web ACL の棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-cloudfront"
require "aws-sdk-wafv2"

module Service
  TOOL = "waf_inventory.rb"
  SNAPSHOT_OPTIONS = { "--scope" => "REGIONAL か CLOUDFRONT。指定しなければ両方" }.freeze
  REGIONAL_RESOURCE_TYPES = %w[APPLICATION_LOAD_BALANCER API_GATEWAY APPSYNC COGNITO_USER_POOL].freeze
  # SDK のメンバー名（snake_case）から API の名前に戻すときに、単純な変換では合わないもの
  API_NAMES = { "ip_set_reference_statement" => "IPSetReferenceStatement" }.freeze

  module_function

  # CLOUDFRONT スコープの Web ACL は us-east-1 にある
  def scope_region(ctx, scope) = scope == "CLOUDFRONT" ? "us-east-1" : nil

  def wafv2(ctx, scope) = ctx.client(:WAFV2, scope_region(ctx, scope))

  # 値が入っている最初のメンバーの名前を、API の名前（例: ManagedRuleGroupStatement、Block）で返す
  def first_member(struct)
    key = struct&.to_h&.keys&.first&.to_s
    key && API_NAMES.fetch(key) { key.split("_").map(&:capitalize).join }
  end

  # ListWebACLs は NextMarker を自分でたどる
  def list_web_acls(ctx, scope)
    acls = []
    marker = nil
    loop do
      params = { scope: scope }
      params[:next_marker] = marker if marker
      page = wafv2(ctx, scope).list_web_acls(**params)
      acls.concat(page.web_acls || [])
      marker = page.next_marker
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
          "name" => acl.name,
          "id" => acl.id,
          "arn" => acl.arn,
          "description" => acl.description,
        })
      end
    end
  end

  # 既定のアクションと、ルールの一覧（優先度・アクション・種類・マネージドルールグループ）
  def rules(ctx, record)
    acl = ctx.pace do
      wafv2(ctx, record["scope"]).get_web_acl(scope: record["scope"], name: record["name"], id: record["id"]).web_acl
    end
    {
      "default_action" => first_member(acl&.default_action),
      "capacity" => acl&.capacity,
      "rules" => (acl&.rules || []).map do |r|
        managed = r.statement&.managed_rule_group_statement
        {
          "name" => r.name,
          "priority" => r.priority,
          "action" => r.action.nil? ? "override:#{first_member(r.override_action)}" : first_member(r.action),
          "statement_type" => first_member(r.statement),
          "managed_rule_group" => managed && "#{managed.vendor_name}/#{managed.name}",
          "rule_group_arn" => r.statement&.rule_group_reference_statement&.arn,
        }
      end,
    }
  end

  # Web ACL を関連付けている先。CLOUDFRONT スコープはディストリビューション、REGIONAL は ALB・API Gateway など
  def resources(ctx, record)
    if record["scope"] == "CLOUDFRONT"
      list = ctx.pace { ctx.client(:CloudFront).list_distributions_by_web_acl_id(web_acl_id: record["arn"]).distribution_list }
      (list&.items || []).map { |d| { "resource_type" => "CLOUDFRONT_DISTRIBUTION", "resource_arn" => d.arn } }
    else
      REGIONAL_RESOURCE_TYPES.flat_map do |type|
        arns = ctx.pace do
          wafv2(ctx, record["scope"]).list_resources_for_web_acl(web_acl_arn: record["arn"], resource_type: type).resource_arns
        end
        (arns || []).map { |arn| { "resource_type" => type, "resource_arn" => arn } }
      end
    end
  end

  # ログの出力先。ログを設定していなければ nil
  def logging(ctx, record)
    config = ctx.pace_or_nil(%w[WAFNonexistentItemException]) do
      wafv2(ctx, record["scope"]).get_logging_configuration(resource_arn: record["arn"])
    end
    config && { "log_destinations" => config.logging_configuration&.log_destination_configs || [] }
  end

  DETAIL_KINDS = {
    "rules" => [%w[wafv2_web_acl], :rules],
    "resources" => [%w[wafv2_web_acl], :resources],
    "logging" => [%w[wafv2_web_acl], :logging],
  }.freeze
end
