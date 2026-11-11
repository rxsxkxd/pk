#!/usr/bin/env bash
# Fargate で動いているタスクの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=fargate-inventory.sh
SNAPSHOT_USAGE='[--cluster NAME]...'
DETAIL_KINDS='task_definition:fargate_task'
# shellcheck source=/dev/null
source "$(dirname "$0")/lib.sh"

snapshot_main() {
  local clusters=() cluster arns
  while [ $# -gt 0 ]; do
    case "$1" in
      --cluster) clusters+=("$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  if [ ${#clusters[@]} -eq 0 ]; then
    aws_json ecs list-clusters | jq -r '.clusterArns[]' >"$work/clusters.txt"
  else
    printf '%s\n' "${clusters[@]}" >"$work/clusters.txt"
  fi

  # 動いている（RUNNING を目指している）Fargate のタスクを、クラスターごとに 100 件ずつまとめて引く
  : >"$work/tasks.jsonl"
  while read -r cluster; do
    aws_json ecs list-tasks --cluster "$cluster" --launch-type FARGATE | jq '.taskArns' | chunks 100 |
      while read -r arns; do
        # shellcheck disable=SC2086 # ARN を別々の引数として渡す
        aws_json ecs describe-tasks --cluster "$cluster" --tasks $arns --include TAGS | jq -c '.tasks[]'
      done >>"$work/tasks.jsonl"
  done <"$work/clusters.txt"

  jq -c -n --argjson common "$common" --slurpfile tasks "$work/tasks.jsonl" "$jq_lib"'
    def eni_detail($name):
      first(.attachments[]? | select(.type == "ElasticNetworkInterface") | .details[]? | select(.name == $name) | .value) // null;

    $tasks[]
    | record("fargate_task"; {
        cluster_name: (.clusterArn | split("/")[-1]),
        task_arn: .taskArn,
        task_definition: .taskDefinitionArn,
        group: .group,
        service_name: (if (.group // "") | startswith("service:") then .group[8:] else null end),
        started_by: .startedBy,
        last_status: .lastStatus,
        desired_status: .desiredStatus,
        health_status: .healthStatus,
        capacity_provider_name: .capacityProviderName,
        platform_version: .platformVersion,
        platform_family: .platformFamily,
        cpu: .cpu,
        memory: .memory,
        ephemeral_storage_gib: .ephemeralStorage.sizeInGiB,
        availability_zone: .availabilityZone,
        subnet_id: eni_detail("subnetId"),
        private_ipv4_address: eni_detail("privateIPv4Address"),
        network_interface_id: eni_detail("networkInterfaceId"),
        enable_execute_command: .enableExecuteCommand,
        started_at: (.startedAt | utc_iso),
        tags: (.tags | tags_object)
      })'
}

describe_task_definition() { aws_paced ecs describe-task-definition --task-definition "$1"; }

# タスク定義の要約。同じタスク定義は 1 回だけ引く
detail_task_definition() {
  local arn
  arn=$(jq -r '.task_definition' <<<"$1")
  cached "td-$arn" describe_task_definition "$arn" | jq -c '.taskDefinition | {
    family,
    revision,
    status,
    cpu,
    memory,
    os_family: .runtimePlatform.operatingSystemFamily,
    cpu_architecture: .runtimePlatform.cpuArchitecture,
    network_mode: .networkMode,
    requires_compatibilities: (.requiresCompatibilities // []),
    task_role_arn: .taskRoleArn,
    execution_role_arn: .executionRoleArn,
    containers: [
      .containerDefinitions[]
      | {
          name,
          image,
          essential,
          cpu,
          memory,
          memory_reservation: .memoryReservation,
          port_mappings: [.portMappings[]? | {container_port: .containerPort, host_port: .hostPort, protocol}],
          log_driver: .logConfiguration.logDriver
        }
    ]
  }'
}

run_main "$@"
