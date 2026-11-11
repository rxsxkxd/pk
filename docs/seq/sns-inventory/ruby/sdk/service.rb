# frozen_string_literal: true

# SNS トピックの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-sns"

module Service
  TOOL = "sns_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  # メールアドレスと電話番号は個人の情報なので出さない
  HIDDEN_ENDPOINT_PROTOCOLS = %w[email email-json sms].freeze

  module_function

  def snapshot(ctx, _opts)
    sns = ctx.client(:SNS)
    topics = sns.list_topics.flat_map(&:topics)
    # サブスクリプションはリージョン全体を 1 回で引き、トピック ARN で突き合わせる
    subs = sns.list_subscriptions.flat_map(&:subscriptions)
    topics.map do |t|
      arn = t.topic_arn
      own = subs.select { |s| s.topic_arn == arn }
      ctx.record("sns_topic", {
        "topic_arn" => arn,
        "topic_name" => arn.split(":").last,
        "fifo" => arn.end_with?(".fifo"),
        "subscription_count" => own.size,
        "subscriptions" => own.map do |s|
          {
            "subscription_arn" => s.subscription_arn,
            "protocol" => s.protocol,
            "endpoint" => HIDDEN_ENDPOINT_PROTOCOLS.include?(s.protocol) ? nil : s.endpoint,
            "pending_confirmation" => s.subscription_arn == "PendingConfirmation",
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
    a = ctx.pace { ctx.client(:SNS).get_topic_attributes(topic_arn: record["topic_arn"]).attributes } || {}
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
    InventoryCommon.tags_object(ctx.pace { ctx.client(:SNS).list_tags_for_resource(resource_arn: record["topic_arn"]).tags })
  end

  DETAIL_KINDS = {
    "attributes" => [%w[sns_topic], :attributes],
    "tags" => [%w[sns_topic], :tags],
  }.freeze
end
