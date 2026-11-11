#!/usr/bin/env bash
# S3 バケットの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=s3-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='security:s3_bucket management:s3_bucket tags:s3_bucket'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  # バケットの一覧はリージョンをまたいで返る。region にはバケットのあるリージョンを入れる
  aws_json s3api list-buckets |
    jq -c --argjson common "$common" "$jq_lib"'
      .Buckets[]
      | record("s3_bucket"; {
          region: .BucketRegion,
          bucket_name: .Name,
          creation_date: (.CreationDate | utc_iso)
        })'
}

s3_or_null() {
  local codes=$1 record=$2 region
  shift 2
  region=$(jq -r '.region // ""' <<<"$record")
  if [ -n "$region" ]; then
    aws_paced_or_null "$codes" s3api "$@" --region "$region"
  else
    aws_paced_or_null "$codes" s3api "$@"
  fi
}

# 暗号化・パブリックアクセスブロック・バケットポリシーの公開状態・オブジェクトの所有者
detail_security() {
  local bucket enc pab status own
  bucket=$(jq -r '.bucket_name' <<<"$1")
  enc=$(s3_or_null ServerSideEncryptionConfigurationNotFoundError "$1" get-bucket-encryption --bucket "$bucket") || return 1
  pab=$(s3_or_null NoSuchPublicAccessBlockConfiguration "$1" get-public-access-block --bucket "$bucket") || return 1
  status=$(s3_or_null NoSuchBucketPolicy "$1" get-bucket-policy-status --bucket "$bucket") || return 1
  own=$(s3_or_null OwnershipControlsNotFoundError "$1" get-bucket-ownership-controls --bucket "$bucket") || return 1
  jq -n -c --argjson enc "$enc" --argjson pab "$pab" --argjson status "$status" --argjson own "$own" '{
    encryption: (
      $enc.ServerSideEncryptionConfiguration.Rules[0]
      | if . == null then null
        else {algorithm: .ApplyServerSideEncryptionByDefault.SSEAlgorithm,
              kms_key_id: .ApplyServerSideEncryptionByDefault.KMSMasterKeyID,
              bucket_key_enabled: .BucketKeyEnabled}
        end
    ),
    public_access_block: (
      $pab.PublicAccessBlockConfiguration
      | if . == null then null
        else {block_public_acls: .BlockPublicAcls, ignore_public_acls: .IgnorePublicAcls,
              block_public_policy: .BlockPublicPolicy, restrict_public_buckets: .RestrictPublicBuckets}
        end
    ),
    has_policy: ($status != null),
    policy_is_public: $status.PolicyStatus.IsPublic,
    object_ownership: $own.OwnershipControls.Rules[0].ObjectOwnership
  }'
}

# バージョニング・ライフサイクル・アクセスログ
detail_management() {
  local bucket ver life log
  bucket=$(jq -r '.bucket_name' <<<"$1")
  ver=$(s3_or_null "" "$1" get-bucket-versioning --bucket "$bucket") || return 1
  life=$(s3_or_null NoSuchLifecycleConfiguration "$1" get-bucket-lifecycle-configuration --bucket "$bucket") || return 1
  log=$(s3_or_null "" "$1" get-bucket-logging --bucket "$bucket") || return 1
  jq -n -c --argjson ver "$ver" --argjson life "$life" --argjson log "$log" '{
    versioning: $ver.Status,
    mfa_delete: $ver.MFADelete,
    lifecycle_rule_count: ($life.Rules // [] | length),
    lifecycle_enabled_rule_count: ($life.Rules // [] | map(select(.Status == "Enabled")) | length),
    logging_target_bucket: $log.LoggingEnabled.TargetBucket,
    logging_target_prefix: $log.LoggingEnabled.TargetPrefix
  }'
}

# タグ。付いていなければ {}
detail_tags() {
  local bucket
  bucket=$(jq -r '.bucket_name' <<<"$1")
  s3_or_null NoSuchTagSet "$1" get-bucket-tagging --bucket "$bucket" | jq -c "$jq_lib"'.TagSet | tags_object'
}

run_main "$@"
