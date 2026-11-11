#!/usr/bin/env bash
# CloudFront ディストリビューションの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=cloudfront-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='config:cloudfront_distribution tags:cloudfront_distribution'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  # CloudFront はリージョンをまたぐサービスなので、region は global にする
  aws_json cloudfront list-distributions | jq -c --argjson common "$common" "$jq_lib"'
    .DistributionList.Items[]?
    | record("cloudfront_distribution"; {
        region: "global",
        distribution_id: .Id,
        arn: .ARN,
        domain_name: .DomainName,
        aliases: (.Aliases.Items // []),
        status: .Status,
        enabled: .Enabled,
        comment: .Comment,
        price_class: .PriceClass,
        http_version: .HttpVersion,
        is_ipv6_enabled: .IsIPV6Enabled,
        web_acl_id: .WebACLId,
        staging: .Staging,
        viewer_certificate: {
          acm_certificate_arn: .ViewerCertificate.ACMCertificateArn,
          cloudfront_default_certificate: .ViewerCertificate.CloudFrontDefaultCertificate,
          minimum_protocol_version: .ViewerCertificate.MinimumProtocolVersion,
          ssl_support_method: .ViewerCertificate.SSLSupportMethod
        },
        origins: [
          .Origins.Items[]?
          | {
              id: .Id,
              domain_name: .DomainName,
              origin_path: .OriginPath,
              origin_type: (if .VpcOriginConfig != null then "vpc" elif .S3OriginConfig != null then "s3" else "custom" end),
              origin_access_control_id: .OriginAccessControlId,
              origin_protocol_policy: .CustomOriginConfig.OriginProtocolPolicy
            }
        ],
        default_cache_behavior: {
          target_origin_id: .DefaultCacheBehavior.TargetOriginId,
          viewer_protocol_policy: .DefaultCacheBehavior.ViewerProtocolPolicy,
          cache_policy_id: .DefaultCacheBehavior.CachePolicyId,
          origin_request_policy_id: .DefaultCacheBehavior.OriginRequestPolicyId,
          function_count: (.DefaultCacheBehavior.FunctionAssociations.Quantity // 0),
          lambda_function_count: (.DefaultCacheBehavior.LambdaFunctionAssociations.Quantity // 0)
        },
        cache_behavior_count: (.CacheBehaviors.Quantity // 0),
        geo_restriction: .Restrictions.GeoRestriction.RestrictionType,
        last_modified_time: (.LastModifiedTime | utc_iso)
      })'
}

# 一覧に入っていない設定（既定のルートオブジェクト・アクセスログ・エラーページなど）
detail_config() {
  local id
  id=$(jq -r '.distribution_id' <<<"$1")
  aws_paced cloudfront get-distribution-config --id "$id" | jq -c '.DistributionConfig | {
    default_root_object: .DefaultRootObject,
    logging_enabled: .Logging.Enabled,
    logging_bucket: .Logging.Bucket,
    logging_prefix: .Logging.Prefix,
    custom_error_response_count: (.CustomErrorResponses.Quantity // 0),
    continuous_deployment_policy_id: .ContinuousDeploymentPolicyId
  }'
}

detail_tags() {
  local arn
  arn=$(jq -r '.arn' <<<"$1")
  aws_paced cloudfront list-tags-for-resource --resource "$arn" | jq -c "$jq_lib"'.Tags.Items | tags_object'
}

run_main "$@"
