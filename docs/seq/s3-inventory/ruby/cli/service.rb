# frozen_string_literal: true

# S3 バケットの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "s3_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def snapshot(ctx, _opts)
    # バケットの一覧はリージョンをまたいで返る。region にはバケットのあるリージョンを入れる
    ctx.call("s3", "list_buckets")["Buckets"].map do |b|
      ctx.record("s3_bucket", {
        "region" => b["BucketRegion"],
        "bucket_name" => b["Name"],
        "creation_date" => InventoryCommon.utc_iso(b["CreationDate"]),
      })
    end
  end

  # バケットのあるリージョンに向けて呼ぶ。「設定が無い」エラーなら nil
  def call_or_nil(ctx, record, codes, operation)
    ctx.call_or_nil(codes, "s3", operation, { "Bucket" => record["bucket_name"] }, record["region"])
  end

  # 暗号化・パブリックアクセスブロック・バケットポリシーの公開状態・オブジェクトの所有者
  def security(ctx, record)
    enc = call_or_nil(ctx, record, %w[ServerSideEncryptionConfigurationNotFoundError], "get_bucket_encryption")
    pab = call_or_nil(ctx, record, %w[NoSuchPublicAccessBlockConfiguration], "get_public_access_block")
    status = call_or_nil(ctx, record, %w[NoSuchBucketPolicy], "get_bucket_policy_status")
    own = call_or_nil(ctx, record, %w[OwnershipControlsNotFoundError], "get_bucket_ownership_controls")

    rule = enc&.dig("ServerSideEncryptionConfiguration", "Rules", 0)
    block = pab&.dig("PublicAccessBlockConfiguration")
    {
      "encryption" => rule && {
        "algorithm" => rule.dig("ApplyServerSideEncryptionByDefault", "SSEAlgorithm"),
        "kms_key_id" => rule.dig("ApplyServerSideEncryptionByDefault", "KMSMasterKeyID"),
        "bucket_key_enabled" => rule["BucketKeyEnabled"],
      },
      "public_access_block" => block && {
        "block_public_acls" => block["BlockPublicAcls"],
        "ignore_public_acls" => block["IgnorePublicAcls"],
        "block_public_policy" => block["BlockPublicPolicy"],
        "restrict_public_buckets" => block["RestrictPublicBuckets"],
      },
      "has_policy" => !status.nil?,
      "policy_is_public" => status&.dig("PolicyStatus", "IsPublic"),
      "object_ownership" => own&.dig("OwnershipControls", "Rules", 0, "ObjectOwnership"),
    }
  end

  # バージョニング・ライフサイクル・アクセスログ
  def management(ctx, record)
    ver = call_or_nil(ctx, record, [], "get_bucket_versioning") || {}
    life = call_or_nil(ctx, record, %w[NoSuchLifecycleConfiguration], "get_bucket_lifecycle_configuration") || {}
    log = (call_or_nil(ctx, record, [], "get_bucket_logging") || {})["LoggingEnabled"] || {}
    rules = life["Rules"] || []
    {
      "versioning" => ver["Status"],
      "mfa_delete" => ver["MFADelete"],
      "lifecycle_rule_count" => rules.size,
      "lifecycle_enabled_rule_count" => rules.count { |r| r["Status"] == "Enabled" },
      "logging_target_bucket" => log["TargetBucket"],
      "logging_target_prefix" => log["TargetPrefix"],
    }
  end

  # タグ。付いていなければ {}
  def tags(ctx, record)
    result = call_or_nil(ctx, record, %w[NoSuchTagSet], "get_bucket_tagging") || {}
    InventoryCommon.tags_object(result["TagSet"])
  end

  DETAIL_KINDS = {
    "security" => [%w[s3_bucket], :security],
    "management" => [%w[s3_bucket], :management],
    "tags" => [%w[s3_bucket], :tags],
  }.freeze
end
