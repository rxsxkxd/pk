# frozen_string_literal: true

# API Gateway の API の棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-apigateway"
require "aws-sdk-apigatewayv2"

module Service
  TOOL = "apigateway_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  # apigatewayv2 の一覧系は next_token をたどって全件を集める
  def all_v2_items(ctx, operation, params = {})
    client = ctx.client(:ApiGatewayV2)
    items = []
    token = nil
    loop do
      resp = client.public_send(operation, **(token ? params.merge(next_token: token) : params))
      items.concat(resp.items || [])
      token = resp.next_token
      break if token.nil? || token.empty?
    end
    items
  end

  def snapshot(ctx, _opts)
    # REST API と、HTTP / WebSocket API（apigatewayv2）は別の API で引く
    rest = ctx.client(:APIGateway).get_rest_apis.flat_map(&:items).map do |a|
      ctx.record("apigateway_rest_api", {
        "api_id" => a.id,
        "name" => a.name,
        "description" => a.description,
        "endpoint_types" => a.endpoint_configuration&.types || [],
        "vpc_endpoint_ids" => a.endpoint_configuration&.vpc_endpoint_ids || [],
        "api_key_source" => a.api_key_source,
        "disable_execute_api_endpoint" => a.disable_execute_api_endpoint,
        "has_resource_policy" => !a.policy.nil?,
        "version" => a.version,
        "created_date" => InventoryCommon.utc_iso(a.created_date),
        "tags" => a.tags || {},
      })
    end
    v2 = all_v2_items(ctx, :get_apis).map do |a|
      ctx.record("apigateway_v2_api", {
        "api_id" => a.api_id,
        "name" => a.name,
        "description" => a.description,
        "protocol_type" => a.protocol_type,
        "api_endpoint" => a.api_endpoint,
        "disable_execute_api_endpoint" => a.disable_execute_api_endpoint,
        "cors_enabled" => !a.cors_configuration.nil?,
        "route_selection_expression" => a.route_selection_expression,
        "created_date" => InventoryCommon.utc_iso(a.created_date),
        "tags" => a.tags || {},
      })
    end
    rest + v2
  end

  # ステージ。REST API と HTTP / WebSocket API で同じ項目にそろえる（片方にしか無い項目は nil）
  def stages(ctx, record)
    if record["record_type"] == "apigateway_rest_api"
      items = ctx.pace { ctx.client(:APIGateway).get_stages(rest_api_id: record["api_id"]).item } || []
      items.map do |s|
        {
          "stage_name" => s.stage_name,
          "deployment_id" => s.deployment_id,
          "auto_deploy" => nil,
          "tracing_enabled" => s.tracing_enabled,
          "cache_cluster_enabled" => s.cache_cluster_enabled,
          "web_acl_arn" => s.web_acl_arn,
          "access_log_destination" => s.access_log_settings&.destination_arn,
          "last_updated_date" => InventoryCommon.utc_iso(s.last_updated_date),
        }
      end
    else
      ctx.pace { all_v2_items(ctx, :get_stages, api_id: record["api_id"]) }.map do |s|
        {
          "stage_name" => s.stage_name,
          "deployment_id" => s.deployment_id,
          "auto_deploy" => s.auto_deploy,
          "tracing_enabled" => nil,
          "cache_cluster_enabled" => nil,
          "web_acl_arn" => nil,
          "access_log_destination" => s.access_log_settings&.destination_arn,
          "last_updated_date" => InventoryCommon.utc_iso(s.last_updated_date),
        }
      end
    end
  end

  # ルート（REST API はリソースのパスとメソッド）と、その行き先（統合）
  def routes(ctx, record)
    if record["record_type"] == "apigateway_rest_api"
      resources = ctx.pace do
        ctx.client(:APIGateway).get_resources(rest_api_id: record["api_id"], embed: ["methods"]).flat_map(&:items)
      end
      resources.flat_map do |r|
        (r.resource_methods || {}).map do |method, m|
          integration = m.method_integration
          {
            "route" => "#{method} #{r.path}",
            "authorization_type" => m.authorization_type,
            "integration_type" => integration&.type,
            "integration_uri" => integration&.uri,
            "connection_type" => integration&.connection_type,
          }
        end
      end
    else
      integrations = ctx.pace { all_v2_items(ctx, :get_integrations, api_id: record["api_id"]) }
      by_id = integrations.to_h { |i| [i.integration_id, i] }
      ctx.pace { all_v2_items(ctx, :get_routes, api_id: record["api_id"]) }.map do |r|
        i = by_id[(r.target || "").delete_prefix("integrations/")]
        {
          "route" => r.route_key,
          "authorization_type" => r.authorization_type,
          "integration_type" => i&.integration_type,
          "integration_uri" => i&.integration_uri,
          "connection_type" => i&.connection_type,
        }
      end
    end
  end

  DETAIL_KINDS = {
    "stages" => [%w[apigateway_rest_api apigateway_v2_api], :stages],
    "routes" => [%w[apigateway_rest_api apigateway_v2_api], :routes],
  }.freeze
end
