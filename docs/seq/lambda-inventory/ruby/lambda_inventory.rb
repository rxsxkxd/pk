#!/usr/bin/env ruby
# frozen_string_literal: true

# Lambda 関数ごとに 設定 / ベース OS / トリガー を JSONL で出力する
#
# API 呼び出しは ListFunctions と ListEventSourceMappings をリージョン全体で 1 回ずつ（ページ分）と、
# 関数ごとの GetPolicy だけ。出力の項目は ../README.md を参照。

require "json"
require "aws-sdk-lambda"

module LambdaInventory
  RUNTIMES_PATH = File.expand_path("../runtimes.json", __dir__)

  module_function

  def run(client: Aws::Lambda::Client.new, out: $stdout, runtimes: JSON.parse(File.read(RUNTIMES_PATH)))
    # レスポンスはページ単位で列挙できる
    functions = client.list_functions.flat_map(&:functions)
    mappings = client.list_event_source_mappings.flat_map(&:event_source_mappings)

    functions.each do |fn|
      policy, error = fetch_policy(client, fn.function_name)
      own_mappings = mappings.select { |m| unqualified(m.function_arn) == fn.function_arn }
      out.puts JSON.generate(record(fn, own_mappings, policy, error, runtimes))
    end
  end

  # ポリシーが無いだけ（ResourceNotFoundException）はエラーにしない
  def fetch_policy(client, name)
    [JSON.parse(client.get_policy(function_name: name).policy), nil]
  rescue Aws::Lambda::Errors::ResourceNotFoundException
    [nil, nil]
  rescue Aws::Lambda::Errors::ServiceError => e
    [nil, { "operation" => "GetPolicy", "code" => e.code, "message" => e.message }]
  end

  def record(fn, mappings, policy, error, runtimes)
    vpc = fn.vpc_config
    {
      "function_name" => fn.function_name,
      "function_arn" => fn.function_arn,
      "description" => fn.description,
      "package_type" => fn.package_type || "Zip",
      "runtime" => fn.runtime,
      "handler" => fn.handler,
      "architecture" => fn.architectures&.first || "x86_64",
      "base_os" => base_os(fn, runtimes),
      "memory_mb" => fn.memory_size,
      "timeout_sec" => fn.timeout,
      "ephemeral_storage_mb" => fn.ephemeral_storage&.size,
      "code_size_bytes" => fn.code_size,
      "last_modified" => fn.last_modified,
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
      "triggers" => (policy&.fetch("Statement", []) || []).map { |st| policy_trigger(st) } +
        mappings.map { |m| mapping_trigger(m) },
      "errors" => [error].compact,
    }
  end

  def base_os(fn, runtimes)
    return "Container Image" if fn.package_type == "Image"

    runtimes.fetch(fn.runtime.to_s, "Unknown")
  end

  def policy_trigger(statement)
    principal = statement["Principal"]
    principal = principal["Service"] || principal["AWS"] if principal.is_a?(Hash)
    condition = statement["Condition"] || {}
    {
      "type" => "resource_policy",
      "sid" => statement["Sid"],
      "effect" => statement["Effect"],
      "principal" => principal,
      "action" => statement["Action"],
      "source_arn" => condition.dig("ArnLike", "AWS:SourceArn") || condition.dig("ArnEquals", "AWS:SourceArn"),
      "source_account" => condition.dig("StringEquals", "AWS:SourceAccount"),
      "function_url_auth_type" => condition.dig("StringEquals", "lambda:FunctionUrlAuthType"),
    }
  end

  def mapping_trigger(mapping)
    {
      "type" => "event_source_mapping",
      "uuid" => mapping.uuid,
      "event_source" => mapping.event_source_arn,
      "self_managed_endpoints" => mapping.self_managed_event_source&.endpoints&.[]("KAFKA_BOOTSTRAP_SERVERS"),
      "topics" => mapping.topics || [],
      "qualifier" => qualifier(mapping.function_arn),
      "state" => mapping.state,
      "batch_size" => mapping.batch_size,
      "maximum_batching_window_sec" => mapping.maximum_batching_window_in_seconds,
      "starting_position" => mapping.starting_position,
      "filter_patterns" => (mapping.filter_criteria&.filters || []).map(&:pattern),
      "on_failure_destination" => mapping.destination_config&.on_failure&.destination,
      "last_processing_result" => mapping.last_processing_result,
    }
  end

  # 関数 ARN の 8 つ目の要素がエイリアスやバージョン
  def qualifier(arn) = arn.split(":")[7]

  def unqualified(arn) = arn.split(":").first(7).join(":")
end

LambdaInventory.run if $PROGRAM_NAME == __FILE__
