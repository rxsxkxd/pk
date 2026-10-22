#!/usr/bin/env bash
# Lambda 関数ごとに 設定 / ベース OS / トリガー を JSONL で出力する
#
# API 呼び出しは ListFunctions と ListEventSourceMappings をリージョン全体で 1 回ずつ（ページ分）と、
# 関数ごとの GetPolicy だけ。出力の項目は ../README.md を参照。
set -euo pipefail

for cmd in aws jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd が必要です" >&2; exit 1; }
done

script_dir=$(cd "$(dirname "$0")" && pwd)
runtimes_file="$script_dir/../runtimes.json"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

aws lambda list-functions --output json >"$work/functions.json"
aws lambda list-event-source-mappings --output json >"$work/mappings.json"

# GetPolicy の結果を関数ごとに 1 行ずつ溜める。
# 失敗したときは CLI のエラーメッセージから操作名・コード・本文を取り出しておく
jq -r '.Functions[].FunctionName' "$work/functions.json" | while read -r name; do
  if policy=$(aws lambda get-policy --function-name "$name" --query Policy --output text 2>"$work/err" </dev/null); then
    jq -nc --arg name "$name" --arg policy "$policy" '{name: $name, policy: ($policy | fromjson), error: null}'
  else
    jq -nc --arg name "$name" --arg err "$(<"$work/err")" '{
      name: $name,
      policy: null,
      error: (
        ($err | capture("\\((?<code>[^)]+)\\) when calling the (?<operation>[A-Za-z]+) operation: (?<message>.*)"))
        // {operation: "GetPolicy", code: "Unknown", message: $err}
      )
    }'
  fi
done >"$work/policies.jsonl"

jq -c -n \
  --slurpfile functions "$work/functions.json" \
  --slurpfile mappings "$work/mappings.json" \
  --slurpfile policies "$work/policies.jsonl" \
  --slurpfile runtimes "$runtimes_file" '
  # 関数 ARN の 8 つ目の要素がエイリアスやバージョン
  def qualifier: split(":")[7];
  def unqualified: split(":")[0:7] | join(":");

  def policy_trigger:
    (.Condition // {}) as $c
    | {
        type: "resource_policy",
        sid: .Sid,
        effect: .Effect,
        principal: (.Principal | if type == "object" then .Service // .AWS else . end),
        action: .Action,
        source_arn: ($c.ArnLike["AWS:SourceArn"] // $c.ArnEquals["AWS:SourceArn"]),
        source_account: $c.StringEquals["AWS:SourceAccount"],
        function_url_auth_type: $c.StringEquals["lambda:FunctionUrlAuthType"]
      };

  def mapping_trigger:
    {
      type: "event_source_mapping",
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
    };

  $runtimes[0] as $os
  | ($policies | map({key: .name, value: .}) | from_entries) as $pol
  | $mappings[0].EventSourceMappings as $esm
  | $functions[0].Functions[]
  | $pol[.FunctionName] as $p
  | .FunctionArn as $arn
  | {
      function_name: .FunctionName,
      function_arn: .FunctionArn,
      description: .Description,
      package_type: (.PackageType // "Zip"),
      runtime: .Runtime,
      handler: .Handler,
      architecture: (.Architectures[0] // "x86_64"),
      base_os: (
        if .PackageType == "Image" then "Container Image"
        else $os[.Runtime // ""] // "Unknown"
        end
      ),
      memory_mb: .MemorySize,
      timeout_sec: .Timeout,
      ephemeral_storage_mb: .EphemeralStorage.Size,
      code_size_bytes: .CodeSize,
      last_modified: .LastModified,
      role: .Role,
      vpc: (
        if (.VpcConfig.VpcId // "") == "" then null
        else {
          vpc_id: .VpcConfig.VpcId,
          subnet_ids: (.VpcConfig.SubnetIds // []),
          security_group_ids: (.VpcConfig.SecurityGroupIds // [])
        }
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
      triggers: (
        [$p.policy.Statement[]? | policy_trigger]
        + [$esm[] | select((.FunctionArn | unqualified) == $arn) | mapping_trigger]
      ),
      # ポリシーが無いだけ（ResourceNotFoundException）はエラーにしない
      errors: [
        $p.error
        | select(. != null and .code != "ResourceNotFoundException")
        | {operation, code, message}
      ]
    }'
