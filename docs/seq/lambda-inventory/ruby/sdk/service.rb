# frozen_string_literal: true

# Lambda 関数の棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-lambda"

module Service
  TOOL = "lambda_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  RUNTIMES = JSON.parse(File.read(File.join(__dir__, "runtimes.json")))

  module_function

  # 関数 ARN の 8 つ目の要素がエイリアスやバージョン
  def qualifier(arn) = arn.split(":")[7]

  def unqualified(arn) = arn.split(":").first(7).join(":")

  def snapshot(ctx, _opts)
    lambda_client = ctx.client(:Lambda)
    functions = lambda_client.list_functions.flat_map(&:functions)
    # イベントソースマッピングはリージョン全体を 1 回で引き、関数 ARN で突き合わせる
    mappings = lambda_client.list_event_source_mappings.flat_map(&:event_source_mappings)
    functions.map do |fn|
      function_record(ctx, fn, mappings.select { |m| unqualified(m.function_arn) == fn.function_arn })
    end
  end

  def function_record(ctx, fn, mappings)
    vpc = fn.vpc_config
    ctx.record("lambda_function", {
      "function_name" => fn.function_name,
      "function_arn" => fn.function_arn,
      "description" => fn.description,
      "package_type" => fn.package_type || "Zip",
      "runtime" => fn.runtime,
      "handler" => fn.handler,
      "architecture" => fn.architectures&.first || "x86_64",
      "base_os" => fn.package_type == "Image" ? "Container Image" : RUNTIMES.fetch(fn.runtime.to_s, "Unknown"),
      "memory_mb" => fn.memory_size,
      "timeout_sec" => fn.timeout,
      "ephemeral_storage_mb" => fn.ephemeral_storage&.size,
      "code_size_bytes" => fn.code_size,
      "last_modified" => InventoryCommon.utc_iso(fn.last_modified),
      "role" => fn.role,
      "vpc" => vpc.nil? || vpc.vpc_id.to_s.empty? ? nil : {
        "vpc_id" => vpc.vpc_id,
        "subnet_ids" => vpc.subnet_ids || [],
        "security_group_ids" => vpc.security_group_ids || [],
      },
      "layers" => (fn.layers || []).map(&:arn),
      "environment_variable_keys" => (fn.environment&.variables || {}).keys.sort,
      "tracing_mode" => fn.tracing_config&.mode,
      "log_group" => fn.logging_config&.log_group,
      "log_format" => fn.logging_config&.log_format,
      "dead_letter_target_arn" => fn.dead_letter_config&.target_arn,
      "kms_key_arn" => fn.kms_key_arn,
      "snap_start" => fn.snap_start&.apply_on,
      "event_source_mappings" => mappings.map { |m| mapping_entry(m) },
    })
  end

  def mapping_entry(m)
    {
      "uuid" => m.uuid,
      "event_source" => m.event_source_arn,
      "self_managed_endpoints" => m.self_managed_event_source&.endpoints&.[]("KAFKA_BOOTSTRAP_SERVERS"),
      "topics" => m.topics || [],
      "qualifier" => qualifier(m.function_arn),
      "state" => m.state,
      "batch_size" => m.batch_size,
      "maximum_batching_window_sec" => m.maximum_batching_window_in_seconds,
      "starting_position" => m.starting_position,
      "filter_patterns" => (m.filter_criteria&.filters || []).map(&:pattern),
      "on_failure_destination" => m.destination_config&.on_failure&.destination,
      "last_processing_result" => m.last_processing_result,
    }
  end

  # リソースベースポリシーで呼び出しを許可している相手。ポリシーが無ければ []
  def policy(ctx, record)
    result = ctx.pace_or_nil(%w[ResourceNotFoundException]) do
      ctx.client(:Lambda).get_policy(function_name: record["function_name"])
    end
    statements = JSON.parse(result&.policy || "{}")["Statement"] || []
    statements.map do |st|
      principal = st["Principal"]
      principal = principal["Service"] || principal["AWS"] if principal.is_a?(Hash)
      condition = st["Condition"] || {}
      {
        "sid" => st["Sid"],
        "effect" => st["Effect"],
        "principal" => principal,
        "action" => st["Action"],
        "source_arn" => condition.dig("ArnLike", "AWS:SourceArn") || condition.dig("ArnEquals", "AWS:SourceArn"),
        "source_account" => condition.dig("StringEquals", "AWS:SourceAccount"),
        "function_url_auth_type" => condition.dig("StringEquals", "lambda:FunctionUrlAuthType"),
      }
    end
  end

  DETAIL_KINDS = {
    "policy" => [%w[lambda_function], :policy],
  }.freeze
end
