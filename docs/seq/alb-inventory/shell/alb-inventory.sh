#!/usr/bin/env bash
# ロードバランサー（ELBv2: ALB・NLB・GWLB）とターゲットグループの棚卸し（シェル版）。
# 使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=alb-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='listeners:elbv2_load_balancer attributes:elbv2_load_balancer target_health:elbv2_target_group'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  aws_json elbv2 describe-load-balancers >"$work/lbs.json"
  aws_json elbv2 describe-target-groups >"$work/tgs.json"

  # タグは 20 件ずつまとめて引く
  jq '[.LoadBalancers[].LoadBalancerArn]' "$work/lbs.json" >"$work/arns-lb.json"
  jq '[.TargetGroups[].TargetGroupArn]' "$work/tgs.json" >"$work/arns-tg.json"
  jq -s 'add' "$work/arns-lb.json" "$work/arns-tg.json" | chunks 20 |
    while read -r arns; do
      # shellcheck disable=SC2086 # ARN を別々の引数として渡す
      aws_json elbv2 describe-tags --resource-arns $arns
    done >"$work/tags.json"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile lbs "$work/lbs.json" \
    --slurpfile tgs "$work/tgs.json" \
    --slurpfile tags "$work/tags.json" "$jq_lib"'
    ([$tags[].TagDescriptions[]] | map({key: .ResourceArn, value: (.Tags | tags_object)}) | from_entries) as $tags_by_arn
    | $tgs[0].TargetGroups as $groups
    | (
        $lbs[0].LoadBalancers[]
        | .LoadBalancerArn as $arn
        | record("elbv2_load_balancer"; {
            load_balancer_name: .LoadBalancerName,
            load_balancer_arn: $arn,
            type: .Type,
            scheme: .Scheme,
            state: .State.Code,
            dns_name: .DNSName,
            vpc_id: .VpcId,
            availability_zones: [.AvailabilityZones[]? | {zone_name: .ZoneName, subnet_id: .SubnetId}],
            security_group_ids: (.SecurityGroups // []),
            ip_address_type: .IpAddressType,
            created_time: (.CreatedTime | utc_iso),
            target_group_arns: [$groups[] | select(any(.LoadBalancerArns[]?; . == $arn)) | .TargetGroupArn],
            tags: ($tags_by_arn[$arn] // {})
          })
      ),
      (
        $groups[]
        | record("elbv2_target_group"; {
            target_group_name: .TargetGroupName,
            target_group_arn: .TargetGroupArn,
            target_type: .TargetType,
            protocol: .Protocol,
            port: .Port,
            vpc_id: .VpcId,
            health_check: {
              protocol: .HealthCheckProtocol,
              path: .HealthCheckPath,
              port: .HealthCheckPort,
              interval_sec: .HealthCheckIntervalSeconds,
              timeout_sec: .HealthCheckTimeoutSeconds,
              healthy_threshold: .HealthyThresholdCount,
              unhealthy_threshold: .UnhealthyThresholdCount,
              matcher: .Matcher.HttpCode
            },
            load_balancer_arns: (.LoadBalancerArns // []),
            tags: ($tags_by_arn[.TargetGroupArn] // {})
          })
      )'
}

# jq: リスナーやルールのアクションを要約する
# shellcheck disable=SC2016
jq_action='
  def action:
    {
      type: .Type,
      target_group_arns: (if .ForwardConfig.TargetGroups != null then [.ForwardConfig.TargetGroups[].TargetGroupArn]
                          elif .TargetGroupArn != null then [.TargetGroupArn] else [] end),
      redirect_status: .RedirectConfig.StatusCode,
      fixed_response_status: .FixedResponseConfig.StatusCode
    };
'

describe_rules() { aws_paced elbv2 describe-rules --listener-arn "$1"; }

# リスナーと、その振り分けルール
detail_listeners() {
  local arn listeners listener rules
  arn=$(jq -r '.load_balancer_arn' <<<"$1")
  listeners=$(aws_paced elbv2 describe-listeners --load-balancer-arn "$arn") || return 1
  for listener in $(jq -r '.Listeners[].ListenerArn' <<<"$listeners"); do
    rules=$(describe_rules "$listener") || exit 1
    jq -c --arg l "$listener" --argjson rules "$rules" "$jq_action"'
      .Listeners[] | select(.ListenerArn == $l)
      | {
          listener_arn: .ListenerArn,
          protocol: .Protocol,
          port: .Port,
          ssl_policy: .SslPolicy,
          certificate_arns: [.Certificates[]?.CertificateArn],
          default_actions: [.DefaultActions[]? | action],
          rules: [
            $rules.Rules[]
            | {
                priority: .Priority,
                is_default: .IsDefault,
                conditions: [
                  .Conditions[]?
                  | {field: .Field,
                     values: (.Values // .HostHeaderConfig.Values // .PathPatternConfig.Values
                              // .HttpRequestMethodConfig.Values // .SourceIpConfig.Values // [])}
                ],
                actions: [.Actions[]? | action]
              }
          ]
        }' <<<"$listeners"
  done | jq -s -c .
}

# ロードバランサーの属性（削除保護・アクセスログ・アイドルタイムアウトなど）
detail_attributes() {
  local arn
  arn=$(jq -r '.load_balancer_arn' <<<"$1")
  aws_paced elbv2 describe-load-balancer-attributes --load-balancer-arn "$arn" |
    jq -c '.Attributes | map({key: .Key, value: .Value}) | from_entries'
}

# ターゲットグループに登録されたターゲットと、そのヘルス
detail_target_health() {
  local arn
  arn=$(jq -r '.target_group_arn' <<<"$1")
  aws_paced elbv2 describe-target-health --target-group-arn "$arn" | jq -c '[
    .TargetHealthDescriptions[]
    | {target_id: .Target.Id, port: .Target.Port, availability_zone: .Target.AvailabilityZone,
       state: .TargetHealth.State, reason: .TargetHealth.Reason, description: .TargetHealth.Description}
  ]'
}

run_main "$@"
