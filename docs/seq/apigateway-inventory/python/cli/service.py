"""API Gateway の API の棚卸し（Python 版の service。SDK 版と CLI 版で同じもの）。出力の項目は ../../DATA.md を参照。"""

from inventory_common import utc_iso

TOOL = "apigateway_inventory.py"
SNAPSHOT_OPTIONS = []


def snapshot(ctx, opts):
    # REST API と、HTTP / WebSocket API（apigatewayv2）は別の API で引く
    for a in ctx.call("apigateway", "get_rest_apis", {}).get("items") or []:
        endpoint = a.get("endpointConfiguration") or {}
        yield ctx.record("apigateway_rest_api", {
            "api_id": a.get("id"),
            "name": a.get("name"),
            "description": a.get("description"),
            "endpoint_types": endpoint.get("types") or [],
            "vpc_endpoint_ids": endpoint.get("vpcEndpointIds") or [],
            "api_key_source": a.get("apiKeySource"),
            "disable_execute_api_endpoint": a.get("disableExecuteApiEndpoint"),
            "has_resource_policy": a.get("policy") is not None,
            "version": a.get("version"),
            "created_date": utc_iso(a.get("createdDate")),
            "tags": a.get("tags") or {},
        })
    for a in ctx.call("apigatewayv2", "get_apis", {}).get("Items") or []:
        yield ctx.record("apigateway_v2_api", {
            "api_id": a.get("ApiId"),
            "name": a.get("Name"),
            "description": a.get("Description"),
            "protocol_type": a.get("ProtocolType"),
            "api_endpoint": a.get("ApiEndpoint"),
            "disable_execute_api_endpoint": a.get("DisableExecuteApiEndpoint"),
            "cors_enabled": a.get("CorsConfiguration") is not None,
            "route_selection_expression": a.get("RouteSelectionExpression"),
            "created_date": utc_iso(a.get("CreatedDate")),
            "tags": a.get("Tags") or {},
        })


def stages(ctx, record):
    """ステージ。REST API と HTTP / WebSocket API で同じ項目にそろえる（片方にしか無い項目は None）。"""
    if record["record_type"] == "apigateway_rest_api":
        items = ctx.call("apigateway", "get_stages", {"restApiId": record["api_id"]}).get("item") or []
        return [
            {
                "stage_name": s.get("stageName"),
                "deployment_id": s.get("deploymentId"),
                "auto_deploy": None,
                "tracing_enabled": s.get("tracingEnabled"),
                "cache_cluster_enabled": s.get("cacheClusterEnabled"),
                "web_acl_arn": s.get("webAclArn"),
                "access_log_destination": (s.get("accessLogSettings") or {}).get("destinationArn"),
                "last_updated_date": utc_iso(s.get("lastUpdatedDate")),
            }
            for s in items
        ]
    items = ctx.call("apigatewayv2", "get_stages", {"ApiId": record["api_id"]}).get("Items") or []
    return [
        {
            "stage_name": s.get("StageName"),
            "deployment_id": s.get("DeploymentId"),
            "auto_deploy": s.get("AutoDeploy"),
            "tracing_enabled": None,
            "cache_cluster_enabled": None,
            "web_acl_arn": None,
            "access_log_destination": (s.get("AccessLogSettings") or {}).get("DestinationArn"),
            "last_updated_date": utc_iso(s.get("LastUpdatedDate")),
        }
        for s in items
    ]


def routes(ctx, record):
    """ルート（REST API はリソースのパスとメソッド）と、その行き先（統合）。"""
    if record["record_type"] == "apigateway_rest_api":
        resources = ctx.call("apigateway", "get_resources", {"restApiId": record["api_id"], "embed": ["methods"]}).get("items") or []
        result = []
        for r in resources:
            for method, m in (r.get("resourceMethods") or {}).items():
                integration = m.get("methodIntegration") or {}
                result.append({
                    "route": f"{method} {r.get('path')}",
                    "authorization_type": m.get("authorizationType"),
                    "integration_type": integration.get("type"),
                    "integration_uri": integration.get("uri"),
                    "connection_type": integration.get("connectionType"),
                })
        return result
    integrations = ctx.call("apigatewayv2", "get_integrations", {"ApiId": record["api_id"]}).get("Items") or []
    by_id = {i.get("IntegrationId"): i for i in integrations}
    result = []
    for r in ctx.call("apigatewayv2", "get_routes", {"ApiId": record["api_id"]}).get("Items") or []:
        i = by_id.get((r.get("Target") or "").removeprefix("integrations/")) or {}
        result.append({
            "route": r.get("RouteKey"),
            "authorization_type": r.get("AuthorizationType"),
            "integration_type": i.get("IntegrationType"),
            "integration_uri": i.get("IntegrationUri"),
            "connection_type": i.get("ConnectionType"),
        })
    return result


DETAIL_KINDS = {
    "stages": (("apigateway_rest_api", "apigateway_v2_api"), stages),
    "routes": (("apigateway_rest_api", "apigateway_v2_api"), routes),
}
