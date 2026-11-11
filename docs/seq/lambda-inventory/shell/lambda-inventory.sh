#!/usr/bin/env bash
# Lambda 関数の棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=lambda-inventory.sh
SNAPSHOT_USAGE=''
DETAIL_KINDS='policy:lambda_function'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  [ $# -eq 0 ] || usage
  aws_json lambda list-functions >"$work/functions.json"
  # イベントソースマッピングはリージョン全体を 1 回で引き、関数 ARN で突き合わせる
  aws_json lambda list-event-source-mappings >"$work/mappings.json"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile functions "$work/functions.json" \
    --slurpfile mappings "$work/mappings.json" \
    --slurpfile runtimes "$lib_dir/runtimes.json" "$jq_lib"'
    # 関数 ARN の 8 つ目の要素がエイリアスやバージョン
    def qualifier: split(":")[7];
    def unqualified: split(":")[0:7] | join(":");

    $runtimes[0] as $os
    | $mappings[0].EventSourceMappings as $esm
    | $functions[0].Functions[]
    | .FunctionArn as $arn
    | record("lambda_function"; {
        function_name: .FunctionName,
        function_arn: .FunctionArn,
        description: .Description,
        package_type: (.PackageType // "Zip"),
        runtime: .Runtime,
        handler: .Handler,
        architecture: (.Architectures[0] // "x86_64"),
        base_os: (if .PackageType == "Image" then "Container Image" else $os[.Runtime // ""] // "Unknown" end),
        memory_mb: .MemorySize,
        timeout_sec: .Timeout,
        ephemeral_storage_mb: .EphemeralStorage.Size,
        code_size_bytes: .CodeSize,
        last_modified: (.LastModified | utc_iso),
        role: .Role,
        vpc: (
          if (.VpcConfig.VpcId // "") == "" then null
          else {vpc_id: .VpcConfig.VpcId, subnet_ids: (.VpcConfig.SubnetIds // []),
                security_group_ids: (.VpcConfig.SecurityGroupIds // [])}
          end
        ),
        layers: [.Layers[]?.Arn],
        environment_variable_keys: (.Environment.Variables // {} | keys),
        tracing_mode: .TracingConfig.Mode,
        log_group: .LoggingConfig.LogGroup,
        log_format: .LoggingConfig.LogFormat,
        dead_letter_target_arn: .DeadLetterConfig.TargetArn,
        kms_key_arn: .KMSKeyArn,
        snap_start: .SnapStart.ApplyOn,
        event_source_mappings: [
          $esm[] | select((.FunctionArn | unqualified) == $arn)
          | {
              uuid: .UUID,
              event_source: .EventSourceArn,
              self_managed_endpoints: .SelfManagedEventSource.Endpoints.KAFKA_BOOTSTRAP_SERVERS,
              topics: (.Topics // []),
              qualifier: (.FunctionArn | qualifier),
              state: .State,
              batch_size: .BatchSize,
              maximum_batching_window_sec: .MaximumBatchingWindowInSeconds,
              starting_position: .StartingPosition,
              filter_patterns: [.FilterCriteria.Filters[]?.Pattern],
              on_failure_destination: .DestinationConfig.OnFailure.Destination,
              last_processing_result: .LastProcessingResult
            }
        ]
      })'
}

# リソースベースポリシーで呼び出しを許可している相手。ポリシーが無ければ []
detail_policy() {
  local name policy
  name=$(jq -r '.function_name' <<<"$1")
  policy=$(aws_paced_or_null ResourceNotFoundException lambda get-policy --function-name "$name") || return 1
  jq -c '
    (.Policy // "{}" | fromjson | .Statement // [])
    | map(
        (.Condition // {}) as $c
        | {
            sid: .Sid,
            effect: .Effect,
            principal: (.Principal | if type == "object" then .Service // .AWS else . end),
            action: .Action,
            source_arn: ($c.ArnLike["AWS:SourceArn"] // $c.ArnEquals["AWS:SourceArn"]),
            source_account: $c.StringEquals["AWS:SourceAccount"],
            function_url_auth_type: $c.StringEquals["lambda:FunctionUrlAuthType"]
          }
      )' <<<"$policy"
}

run_main "$@"
