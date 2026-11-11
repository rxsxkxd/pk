# frozen_string_literal: true

# API Gateway の API の棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "apigateway_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def snapshot(ctx, _opts)
    # REST API と、HTTP / WebSocket API（apigatewayv2）は別の API で引く
    rest = (ctx.call("apigateway", "get_rest_apis")["items"] || []).map do |a|
      ctx.record("apigateway_rest_api", {
        "api_id" => a["id"],
        "name" => a["name"],
        "description" => a["description"],
        "endpoint_types" => a.dig("endpointConfiguration", "types") || [],
        "vpc_endpoint_ids" => a.dig("endpointConfiguration", "vpcEndpointIds") || [],
        "api_key_source" => a["apiKeySource"],
        "disable_execute_api_endpoint" => a["disableExecuteApiEndpoint"],
        "has_resource_policy" => !a["policy"].nil?,
        "version" => a["version"],
        "created_date" => InventoryCommon.utc_iso(a["createdDate"]),
        "tags" => a["tags"] || {},
      })
    end
    v2 = (ctx.call("apigatewayv2", "get_apis")["Items"] || []).map do |a|
      ctx.record("apigateway_v2_api", {
        "api_id" => a["ApiId"],
        "name" => a["Name"],
        "description" => a["Description"],
        "protocol_type" => a["ProtocolType"],
        "api_endpoint" => a["ApiEndpoint"],
        "disable_execute_api_endpoint" => a["DisableExecuteApiEndpoint"],
        "cors_enabled" => !a["CorsConfiguration"].nil?,
        "route_selection_expression" => a["RouteSelectionExpression"],
        "created_date" => InventoryCommon.utc_iso(a["CreatedDate"]),
        "tags" => a["Tags"] || {},
      })
    end
    rest + v2
  end

  # ステージ。REST API と HTTP / WebSocket API で同じ項目にそろえる（片方にしか無い項目は nil）
  def stages(ctx, record)
    if record["record_type"] == "apigateway_rest_api"
      (ctx.call("apigateway", "get_stages", { "restApiId" => record["api_id"] })["item"] || []).map do |s|
        {
          "stage_name" => s["stageName"],
          "deployment_id" => s["deploymentId"],
          "auto_deploy" => nil,
          "tracing_enabled" => s["tracingEnabled"],
          "cache_cluster_enabled" => s["cacheClusterEnabled"],
          "web_acl_arn" => s["webAclArn"],
          "access_log_destination" => s.dig("accessLogSettings", "destinationArn"),
          "last_updated_date" => InventoryCommon.utc_iso(s["lastUpdatedDate"]),
        }
      end
    else
      (ctx.call("apigatewayv2", "get_stages", { "ApiId" => record["api_id"] })["Items"] || []).map do |s|
        {
          "stage_name" => s["StageName"],
          "deployment_id" => s["DeploymentId"],
          "auto_deploy" => s["AutoDeploy"],
          "tracing_enabled" => nil,
          "cache_cluster_enabled" => nil,
          "web_acl_arn" => nil,
          "access_log_destination" => s.dig("AccessLogSettings", "DestinationArn"),
          "last_updated_date" => InventoryCommon.utc_iso(s["LastUpdatedDate"]),
        }
      end
    end
  end

  # ルート（REST API はリソースのパスとメソッド）と、その行き先（統合）
  def routes(ctx, record)
    if record["record_type"] == "apigateway_rest_api"
      resources = ctx.call("apigateway", "get_resources", { "restApiId" => record["api_id"], "embed" => ["methods"] })["items"] || []
      resources.flat_map do |r|
        (r["resourceMethods"] || {}).map do |method, m|
          integration = m["methodIntegration"] || {}
          {
            "route" => "#{method} #{r['path']}",
            "authorization_type" => m["authorizationType"],
            "integration_type" => integration["type"],
            "integration_uri" => integration["uri"],
            "connection_type" => integration["connectionType"],
          }
        end
      end
    else
      integrations = ctx.call("apigatewayv2", "get_integrations", { "ApiId" => record["api_id"] })["Items"] || []
      by_id = integrations.to_h { |i| [i["IntegrationId"], i] }
      (ctx.call("apigatewayv2", "get_routes", { "ApiId" => record["api_id"] })["Items"] || []).map do |r|
        i = by_id[(r["Target"] || "").delete_prefix("integrations/")] || {}
        {
          "route" => r["RouteKey"],
          "authorization_type" => r["AuthorizationType"],
          "integration_type" => i["IntegrationType"],
          "integration_uri" => i["IntegrationUri"],
          "connection_type" => i["ConnectionType"],
        }
      end
    end
  end

  DETAIL_KINDS = {
    "stages" => [%w[apigateway_rest_api apigateway_v2_api], :stages],
    "routes" => [%w[apigateway_rest_api apigateway_v2_api], :routes],
  }.freeze
end
