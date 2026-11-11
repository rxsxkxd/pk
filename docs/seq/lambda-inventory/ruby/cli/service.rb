# frozen_string_literal: true

# Lambda 関数の棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "lambda_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  RUNTIMES = JSON.parse(File.read(File.join(__dir__, "runtimes.json")))

  module_function

  # 関数 ARN の 8 つ目の要素がエイリアスやバージョン
  def qualifier(arn) = arn.split(":")[7]

  def unqualified(arn) = arn.split(":").first(7).join(":")

  def snapshot(ctx, _opts)
    functions = ctx.call("lambda", "list_functions")["Functions"]
    # イベントソースマッピングはリージョン全体を 1 回で引き、関数 ARN で突き合わせる
    mappings = ctx.call("lambda", "list_event_source_mappings")["EventSourceMappings"]
    functions.map do |fn|
      function_record(ctx, fn, mappings.select { |m| unqualified(m["FunctionArn"]) == fn["FunctionArn"] })
    end
  end

  def function_record(ctx, fn, mappings)
    vpc = fn["VpcConfig"]
    ctx.record("lambda_function", {
      "function_name" => fn["FunctionName"],
      "function_arn" => fn["FunctionArn"],
      "description" => fn["Description"],
      "package_type" => fn["PackageType"] || "Zip",
      "runtime" => fn["Runtime"],
      "handler" => fn["Handler"],
      "architecture" => (fn["Architectures"] || []).first || "x86_64",
      "base_os" => fn["PackageType"] == "Image" ? "Container Image" : RUNTIMES.fetch(fn["Runtime"].to_s, "Unknown"),
      "memory_mb" => fn["MemorySize"],
      "timeout_sec" => fn["Timeout"],
      "ephemeral_storage_mb" => fn.dig("EphemeralStorage", "Size"),
      "code_size_bytes" => fn["CodeSize"],
      "last_modified" => InventoryCommon.utc_iso(fn["LastModified"]),
      "role" => fn["Role"],
      "vpc" => vpc.nil? || vpc["VpcId"].to_s.empty? ? nil : {
        "vpc_id" => vpc["VpcId"],
        "subnet_ids" => vpc["SubnetIds"] || [],
        "security_group_ids" => vpc["SecurityGroupIds"] || [],
      },
      "layers" => (fn["Layers"] || []).map { |l| l["Arn"] },
      "environment_variable_keys" => (fn.dig("Environment", "Variables") || {}).keys.sort,
      "tracing_mode" => fn.dig("TracingConfig", "Mode"),
      "log_group" => fn.dig("LoggingConfig", "LogGroup"),
      "log_format" => fn.dig("LoggingConfig", "LogFormat"),
      "dead_letter_target_arn" => fn.dig("DeadLetterConfig", "TargetArn"),
      "kms_key_arn" => fn["KMSKeyArn"],
      "snap_start" => fn.dig("SnapStart", "ApplyOn"),
      "event_source_mappings" => mappings.map { |m| mapping_entry(m) },
    })
  end

  def mapping_entry(m)
    {
      "uuid" => m["UUID"],
      "event_source" => m["EventSourceArn"],
      "self_managed_endpoints" => m.dig("SelfManagedEventSource", "Endpoints", "KAFKA_BOOTSTRAP_SERVERS"),
      "topics" => m["Topics"] || [],
      "qualifier" => qualifier(m["FunctionArn"]),
      "state" => m["State"],
      "batch_size" => m["BatchSize"],
      "maximum_batching_window_sec" => m["MaximumBatchingWindowInSeconds"],
      "starting_position" => m["StartingPosition"],
      "filter_patterns" => (m.dig("FilterCriteria", "Filters") || []).map { |f| f["Pattern"] },
      "on_failure_destination" => m.dig("DestinationConfig", "OnFailure", "Destination"),
      "last_processing_result" => m["LastProcessingResult"],
    }
  end

  # リソースベースポリシーで呼び出しを許可している相手。ポリシーが無ければ []
  def policy(ctx, record)
    result = ctx.call_or_nil(%w[ResourceNotFoundException], "lambda", "get_policy", { "FunctionName" => record["function_name"] })
    statements = JSON.parse(result&.dig("Policy") || "{}")["Statement"] || []
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
