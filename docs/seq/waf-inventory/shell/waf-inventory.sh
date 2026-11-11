#!/usr/bin/env bash
# WAF（wafv2）の Web ACL の棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=waf-inventory.sh
SNAPSHOT_USAGE='[--scope REGIONAL|CLOUDFRONT]...'
DETAIL_KINDS='rules:wafv2_web_acl resources:wafv2_web_acl logging:wafv2_web_acl'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

# CLOUDFRONT スコープの Web ACL は us-east-1 にある
scope_region() {
  if [ "$1" = CLOUDFRONT ]; then echo us-east-1; else current_region; fi
}

# ListWebACLs は NextMarker を自分でたどる
list_web_acls() {
  local scope=$1 region marker="" page
  region=$(scope_region "$scope")
  while :; do
    if [ -n "$marker" ]; then
      page=$(aws_json wafv2 list-web-acls --scope "$scope" --region "$region" --next-marker "$marker")
    else
      page=$(aws_json wafv2 list-web-acls --scope "$scope" --region "$region")
    fi
    jq -c --arg scope "$scope" '.WebACLs[]? + {Scope: $scope}' <<<"$page"
    marker=$(jq -r '.NextMarker // ""' <<<"$page")
    [ -n "$marker" ] || break
  done
}

snapshot_main() {
  local scopes=() scope
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope) scopes+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  [ ${#scopes[@]} -gt 0 ] || scopes=(REGIONAL CLOUDFRONT)

  for scope in "${scopes[@]}"; do
    list_web_acls "$scope"
  done | jq -c --argjson common "$common" "$jq_lib"'
    record("wafv2_web_acl"; {
      region: (if .Scope == "CLOUDFRONT" then "global" else $common.region end),
      scope: .Scope,
      name: .Name,
      id: .Id,
      arn: .ARN,
      description: .Description
    })'
}

# 既定のアクションと、ルールの一覧（優先度・アクション・種類・マネージドルールグループ）
detail_rules() {
  local scope name id
  scope=$(jq -r '.scope' <<<"$1")
  name=$(jq -r '.name' <<<"$1")
  id=$(jq -r '.id' <<<"$1")
  aws_paced wafv2 get-web-acl --scope "$scope" --name "$name" --id "$id" --region "$(scope_region "$scope")" | jq -c '
    .WebACL | {
      default_action: (.DefaultAction | keys_unsorted[0]),
      capacity: .Capacity,
      rules: [
        .Rules[]?
        | {
            name: .Name,
            priority: .Priority,
            action: (if .Action != null then (.Action | keys_unsorted[0])
                     else "override:" + (.OverrideAction | keys_unsorted[0]) end),
            statement_type: (.Statement | keys_unsorted[0]),
            managed_rule_group: (.Statement.ManagedRuleGroupStatement
                                 | if . == null then null else "\(.VendorName)/\(.Name)" end),
            rule_group_arn: .Statement.RuleGroupReferenceStatement.ARN
          }
      ]
    }'
}

# Web ACL を関連付けている先。CLOUDFRONT スコープはディストリビューション、REGIONAL は ALB・API Gateway など
detail_resources() {
  local scope arn type
  scope=$(jq -r '.scope' <<<"$1")
  arn=$(jq -r '.arn' <<<"$1")
  if [ "$scope" = CLOUDFRONT ]; then
    aws_paced cloudfront list-distributions-by-web-acl-id --web-acl-id "$arn" |
      jq -c '[.DistributionList.Items[]? | {resource_type: "CLOUDFRONT_DISTRIBUTION", resource_arn: .ARN}]'
  else
    for type in APPLICATION_LOAD_BALANCER API_GATEWAY APPSYNC COGNITO_USER_POOL; do
      aws_paced wafv2 list-resources-for-web-acl --web-acl-arn "$arn" --resource-type "$type" |
        jq -c --arg t "$type" '.ResourceArns[]? | {resource_type: $t, resource_arn: .}' || exit 1
    done | jq -s -c .
  fi
}

# ログの出力先。ログを設定していなければ null
detail_logging() {
  local scope arn config
  scope=$(jq -r '.scope' <<<"$1")
  arn=$(jq -r '.arn' <<<"$1")
  config=$(aws_paced_or_null WAFNonexistentItemException wafv2 get-logging-configuration \
    --resource-arn "$arn" --region "$(scope_region "$scope")") || return 1
  jq -c 'if . == null then null else {log_destinations: (.LoggingConfiguration.LogDestinationConfigs // [])} end' <<<"$config"
}

run_main "$@"
