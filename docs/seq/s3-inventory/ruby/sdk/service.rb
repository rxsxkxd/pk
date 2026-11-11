# frozen_string_literal: true

# S3 バケットの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-s3"

module Service
  TOOL = "s3_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def snapshot(ctx, _opts)
    # バケットの一覧はリージョンをまたいで返る。region にはバケットのあるリージョンを入れる
    ctx.client(:S3).list_buckets.flat_map(&:buckets).map do |b|
      ctx.record("s3_bucket", {
        "region" => b.bucket_region,
        "bucket_name" => b.name,
        "creation_date" => InventoryCommon.utc_iso(b.creation_date),
      })
    end
  end

  # バケットのあるリージョンに向けて呼ぶ。「設定が無い」エラーなら nil
  def call_or_nil(ctx, record, codes, operation)
    s3 = ctx.client(:S3, record["region"])
    ctx.pace_or_nil(codes) { s3.public_send(operation, bucket: record["bucket_name"]) }
  end

  # 暗号化・パブリックアクセスブロック・バケットポリシーの公開状態・オブジェクトの所有者
  def security(ctx, record)
    enc = call_or_nil(ctx, record, %w[ServerSideEncryptionConfigurationNotFoundError], :get_bucket_encryption)
    pab = call_or_nil(ctx, record, %w[NoSuchPublicAccessBlockConfiguration], :get_public_access_block)
    status = call_or_nil(ctx, record, %w[NoSuchBucketPolicy], :get_bucket_policy_status)
    own = call_or_nil(ctx, record, %w[OwnershipControlsNotFoundError], :get_bucket_ownership_controls)

    rule = enc&.server_side_encryption_configuration&.rules&.first
    block = pab&.public_access_block_configuration
    {
      "encryption" => rule && {
        "algorithm" => rule.apply_server_side_encryption_by_default&.sse_algorithm,
        "kms_key_id" => rule.apply_server_side_encryption_by_default&.kms_master_key_id,
        "bucket_key_enabled" => rule.bucket_key_enabled,
      },
      "public_access_block" => block && {
        "block_public_acls" => block.block_public_acls,
        "ignore_public_acls" => block.ignore_public_acls,
        "block_public_policy" => block.block_public_policy,
        "restrict_public_buckets" => block.restrict_public_buckets,
      },
      "has_policy" => !status.nil?,
      "policy_is_public" => status&.policy_status&.is_public,
      "object_ownership" => own&.ownership_controls&.rules&.first&.object_ownership,
    }
  end

  # バージョニング・ライフサイクル・アクセスログ
  def management(ctx, record)
    ver = call_or_nil(ctx, record, [], :get_bucket_versioning)
    life = call_or_nil(ctx, record, %w[NoSuchLifecycleConfiguration], :get_bucket_lifecycle_configuration)
    log = call_or_nil(ctx, record, [], :get_bucket_logging)&.logging_enabled
    rules = life&.rules || []
    {
      "versioning" => ver&.status,
      "mfa_delete" => ver&.mfa_delete,
      "lifecycle_rule_count" => rules.size,
      "lifecycle_enabled_rule_count" => rules.count { |r| r.status == "Enabled" },
      "logging_target_bucket" => log&.target_bucket,
      "logging_target_prefix" => log&.target_prefix,
    }
  end

  # タグ。付いていなければ {}
  def tags(ctx, record)
    InventoryCommon.tags_object(call_or_nil(ctx, record, %w[NoSuchTagSet], :get_bucket_tagging)&.tag_set)
  end

  DETAIL_KINDS = {
    "security" => [%w[s3_bucket], :security],
    "management" => [%w[s3_bucket], :management],
    "tags" => [%w[s3_bucket], :tags],
  }.freeze
end
