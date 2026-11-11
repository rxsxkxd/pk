# frozen_string_literal: true

# SQS キューの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-sqs"

module Service
  TOOL = "sqs_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze

  module_function

  def snapshot(ctx, _opts)
    # キューが 1 つも無いと、queue_urls は空になる
    ctx.client(:SQS).list_queues.flat_map { |page| page.queue_urls || [] }.map do |url|
      ctx.record("sqs_queue", {
        "queue_url" => url,
        "queue_name" => url.split("/").last,
        "fifo" => url.end_with?(".fifo"),
      })
    end
  end

  # 条件なしで、だれにでも（Principal が *）許可している文の数
  def public_statement_count(statements)
    statements.count do |st|
      principal = st["Principal"]
      principal = principal["AWS"] if principal.is_a?(Hash)
      st["Effect"] == "Allow" && st["Condition"].nil? && Array(principal).include?("*")
    end
  end

  def to_int(value) = value&.to_i

  def to_bool(value) = value.nil? ? nil : value == "true"

  # キューの設定・溜まっているメッセージ数・デッドレターキュー・暗号化・アクセスポリシーの要約
  def attributes(ctx, record)
    a = ctx.pace do
      ctx.client(:SQS).get_queue_attributes(queue_url: record["queue_url"], attribute_names: ["All"]).attributes
    end || {}
    redrive = JSON.parse(a["RedrivePolicy"] || "{}")
    statements = JSON.parse(a["Policy"] || "{}")["Statement"] || []
    {
      "queue_arn" => a["QueueArn"],
      "visibility_timeout_sec" => to_int(a["VisibilityTimeout"]),
      "message_retention_sec" => to_int(a["MessageRetentionPeriod"]),
      "maximum_message_size" => to_int(a["MaximumMessageSize"]),
      "delay_sec" => to_int(a["DelaySeconds"]),
      "receive_wait_time_sec" => to_int(a["ReceiveMessageWaitTimeSeconds"]),
      "approximate_messages" => to_int(a["ApproximateNumberOfMessages"]),
      "approximate_messages_not_visible" => to_int(a["ApproximateNumberOfMessagesNotVisible"]),
      "approximate_messages_delayed" => to_int(a["ApproximateNumberOfMessagesDelayed"]),
      "dead_letter_target_arn" => redrive["deadLetterTargetArn"],
      "max_receive_count" => redrive["maxReceiveCount"],
      "kms_master_key_id" => a["KmsMasterKeyId"],
      "sqs_managed_sse_enabled" => to_bool(a["SqsManagedSseEnabled"]),
      "content_based_deduplication" => to_bool(a["ContentBasedDeduplication"]),
      "created_at" => InventoryCommon.epoch_iso(a["CreatedTimestamp"]),
      "last_modified_at" => InventoryCommon.epoch_iso(a["LastModifiedTimestamp"]),
      "policy_statement_count" => statements.size,
      "policy_public_statement_count" => public_statement_count(statements),
    }
  end

  def tags(ctx, record)
    ctx.pace { ctx.client(:SQS).list_queue_tags(queue_url: record["queue_url"]).tags } || {}
  end

  DETAIL_KINDS = {
    "attributes" => [%w[sqs_queue], :attributes],
    "tags" => [%w[sqs_queue], :tags],
  }.freeze
end
