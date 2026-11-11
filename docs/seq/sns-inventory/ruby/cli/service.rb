# frozen_string_literal: true

# SNS トピックの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "sns_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  # メールアドレスと電話番号は個人の情報なので出さない
  HIDDEN_ENDPOINT_PROTOCOLS = %w[email email-json sms].freeze

  module_function

  def snapshot(ctx, _opts)
    topics = ctx.call("sns", "list_topics")["Topics"]
    # サブスクリプションはリージョン全体を 1 回で引き、トピック ARN で突き合わせる
    subs = ctx.call("sns", "list_subscriptions")["Subscriptions"]
    topics.map do |t|
      arn = t["TopicArn"]
      own = subs.select { |s| s["TopicArn"] == arn }
      ctx.record("sns_topic", {
        "topic_arn" => arn,
        "topic_name" => arn.split(":").last,
        "fifo" => arn.end_with?(".fifo"),
        "subscription_count" => own.size,
        "subscriptions" => own.map do |s|
          {
            "subscription_arn" => s["SubscriptionArn"],
            "protocol" => s["Protocol"],
            "endpoint" => HIDDEN_ENDPOINT_PROTOCOLS.include?(s["Protocol"]) ? nil : s["Endpoint"],
            "pending_confirmation" => s["SubscriptionArn"] == "PendingConfirmation",
          }
        end,
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

  # 暗号化・配信の状況・アクセスポリシーの要約
  def attributes(ctx, record)
    a = ctx.call("sns", "get_topic_attributes", { "TopicArn" => record["topic_arn"] })["Attributes"] || {}
    statements = JSON.parse(a["Policy"] || "{}")["Statement"] || []
    {
      "display_name" => a["DisplayName"],
      "kms_master_key_id" => a["KmsMasterKeyId"],
      "subscriptions_confirmed" => to_int(a["SubscriptionsConfirmed"]),
      "subscriptions_pending" => to_int(a["SubscriptionsPending"]),
      "content_based_deduplication" => to_bool(a["ContentBasedDeduplication"]),
      "tracing_config" => a["TracingConfig"],
      "signature_version" => a["SignatureVersion"],
      "policy_statement_count" => statements.size,
      "policy_public_statement_count" => public_statement_count(statements),
    }
  end

  def tags(ctx, record)
    InventoryCommon.tags_object(ctx.call("sns", "list_tags_for_resource", { "ResourceArn" => record["topic_arn"] })["Tags"])
  end

  DETAIL_KINDS = {
    "attributes" => [%w[sns_topic], :attributes],
    "tags" => [%w[sns_topic], :tags],
  }.freeze
end
