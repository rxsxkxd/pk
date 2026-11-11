#!/usr/bin/env bash
# API Gateway の API の棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=apigateway-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='stages:apigateway_rest_api,apigateway_v2_api routes:apigateway_rest_api,apigateway_v2_api'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  # REST API と、HTTP / WebSocket API（apigatewayv2）は別の API で引く
  aws_json apigateway get-rest-apis >"$work/rest.json"
  aws_json apigatewayv2 get-apis >"$work/v2.json"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile rest "$work/rest.json" \
    --slurpfile v2 "$work/v2.json" "$jq_lib"'
    (
      $rest[0].items[]?
      | record("apigateway_rest_api"; {
          api_id: .id,
          name: .name,
          description: .description,
          endpoint_types: (.endpointConfiguration.types // []),
          vpc_endpoint_ids: (.endpointConfiguration.vpcEndpointIds // []),
          api_key_source: .apiKeySource,
          disable_execute_api_endpoint: .disableExecuteApiEndpoint,
          has_resource_policy: (.policy != null),
          version: .version,
          created_date: (.createdDate | utc_iso),
          tags: (.tags // {})
        })
    ),
    (
      $v2[0].Items[]?
      | record("apigateway_v2_api"; {
          api_id: .ApiId,
          name: .Name,
          description: .Description,
          protocol_type: .ProtocolType,
          api_endpoint: .ApiEndpoint,
          disable_execute_api_endpoint: .DisableExecuteApiEndpoint,
          cors_enabled: (.CorsConfiguration != null),
          route_selection_expression: .RouteSelectionExpression,
          created_date: (.CreatedDate | utc_iso),
          tags: (.Tags // {})
        })
    )'
}

# ステージ。REST API と HTTP / WebSocket API で同じ項目にそろえる（片方にしか無い項目は null）
detail_stages() {
  local type id
  type=$(jq -r '.record_type' <<<"$1")
  id=$(jq -r '.api_id' <<<"$1")
  if [ "$type" = apigateway_rest_api ]; then
    aws_paced apigateway get-stages --rest-api-id "$id" | jq -c "$jq_lib"'[
      .item[]?
      | {stage_name: .stageName, deployment_id: .deploymentId, auto_deploy: null,
         tracing_enabled: .tracingEnabled, cache_cluster_enabled: .cacheClusterEnabled, web_acl_arn: .webAclArn,
         access_log_destination: .accessLogSettings.destinationArn, last_updated_date: (.lastUpdatedDate | utc_iso)}
    ]'
  else
    aws_paced apigatewayv2 get-stages --api-id "$id" | jq -c "$jq_lib"'[
      .Items[]?
      | {stage_name: .StageName, deployment_id: .DeploymentId, auto_deploy: .AutoDeploy,
         tracing_enabled: null, cache_cluster_enabled: null, web_acl_arn: null,
         access_log_destination: .AccessLogSettings.DestinationArn, last_updated_date: (.LastUpdatedDate | utc_iso)}
    ]'
  fi
}

# ルート（REST API はリソースのパスとメソッド）と、その行き先（統合）
detail_routes() {
  local type id integrations
  type=$(jq -r '.record_type' <<<"$1")
  id=$(jq -r '.api_id' <<<"$1")
  if [ "$type" = apigateway_rest_api ]; then
    aws_paced apigateway get-resources --rest-api-id "$id" --embed methods | jq -c '[
      .items[]? as $r
      | ($r.resourceMethods // {}) | to_entries[]
      | {route: "\(.key) \($r.path)", authorization_type: .value.authorizationType,
         integration_type: .value.methodIntegration.type, integration_uri: .value.methodIntegration.uri,
         connection_type: .value.methodIntegration.connectionType}
    ]'
  else
    integrations=$(aws_paced apigatewayv2 get-integrations --api-id "$id") || return 1
    aws_paced apigatewayv2 get-routes --api-id "$id" | jq -c --argjson integrations "$integrations" '
      ($integrations.Items // [] | map({key: .IntegrationId, value: .}) | from_entries) as $by_id
      | [
          .Items[]?
          | $by_id[(.Target // "") | ltrimstr("integrations/")] as $i
          | {route: .RouteKey, authorization_type: .AuthorizationType,
             integration_type: $i.IntegrationType, integration_uri: $i.IntegrationUri,
             connection_type: $i.ConnectionType}
        ]'
  fi
}

run_main "$@"
