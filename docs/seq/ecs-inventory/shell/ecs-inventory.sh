#!/usr/bin/env bash
# ECS のサービスとコンテナインスタンスの棚卸し（シェル版）。使い方は ../README.md、出力の項目は ../DATA.md を参照。
TOOL=ecs-inventory.sh
SNAPSHOT_USAGE='[--cluster NAME]...'
DETAIL_KINDS='task_definition:ecs_service tasks:ecs_service'
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

  : >"$work/services.jsonl"
  : >"$work/container-instances.jsonl"
  while read -r cluster; do
    aws_json ecs list-services --cluster "$cluster" | jq '.serviceArns' | chunks 10 |
      while read -r arns; do
        # shellcheck disable=SC2086 # ARN を別々の引数として渡す
        aws_json ecs describe-services --cluster "$cluster" --services $arns --include TAGS | jq -c '.services[]'
      done >>"$work/services.jsonl"

    # コンテナインスタンスの応答にはクラスターが入っていないので足しておく
    aws_json ecs list-container-instances --cluster "$cluster" | jq '.containerInstanceArns' | chunks 100 |
      while read -r arns; do
        # shellcheck disable=SC2086
        aws_json ecs describe-container-instances --cluster "$cluster" --container-instances $arns |
          jq -c --arg cluster "$cluster" '.containerInstances[] | . + {clusterArn: $cluster}'
      done >>"$work/container-instances.jsonl"
  done <"$work/clusters.txt"

  jq -c -n \
    --argjson common "$common" \
    --slurpfile services "$work/services.jsonl" \
    --slurpfile instances "$work/container-instances.jsonl" "$jq_lib"'
    def cluster_name: split("/")[-1];
    def attribute($name): first(.attributes[]? | select(.name == $name) | .value) // null;

    (
      $services[]
      | record("ecs_service"; {
          cluster_name: (.clusterArn | cluster_name),
          service_name: .serviceName,
          service_arn: .serviceArn,
          status: .status,
          launch_type: .launchType,
          capacity_provider_strategy: [.capacityProviderStrategy[]? | {capacity_provider: .capacityProvider, weight, base}],
          platform_version: .platformVersion,
          platform_family: .platformFamily,
          scheduling_strategy: .schedulingStrategy,
          desired_count: .desiredCount,
          running_count: .runningCount,
          pending_count: .pendingCount,
          task_definition: .taskDefinition,
          load_balancers: [
            .loadBalancers[]?
            | {target_group_arn: .targetGroupArn, load_balancer_name: .loadBalancerName,
               container_name: .containerName, container_port: .containerPort}
          ],
          service_registries: [.serviceRegistries[]?.registryArn],
          network: (
            .networkConfiguration.awsvpcConfiguration
            | if . == null then null
              else {subnets: (.subnets // []), security_groups: (.securityGroups // []), assign_public_ip: .assignPublicIp}
              end
          ),
          deployment_circuit_breaker: (
            .deploymentConfiguration.deploymentCircuitBreaker | if . == null then null else {enable, rollback} end
          ),
          enable_execute_command: .enableExecuteCommand,
          created_at: (.createdAt | utc_iso),
          tags: (.tags | tags_object)
        })
    ),
    (
      $instances[]
      | record("ecs_container_instance"; {
          cluster_name: (.clusterArn | cluster_name),
          container_instance_arn: .containerInstanceArn,
          ec2_instance_id: .ec2InstanceId,
          status: .status,
          agent_connected: .agentConnected,
          agent_version: .versionInfo.agentVersion,
          docker_version: .versionInfo.dockerVersion,
          os_type: attribute("ecs.os-type"),
          os_family: attribute("ecs.os-family"),
          cpu_architecture: attribute("ecs.cpu-architecture"),
          ami_id: attribute("ecs.ami-id"),
          instance_type: attribute("ecs.instance-type"),
          capacity_provider_name: .capacityProviderName,
          running_tasks_count: .runningTasksCount,
          pending_tasks_count: .pendingTasksCount,
          registered_at: (.registeredAt | utc_iso)
        })
    )'
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

# サービスのタスクと、それが動いているホスト
detail_tasks() {
  local cluster service arns
  cluster=$(jq -r '.cluster_name' <<<"$1")
  service=$(jq -r '.service_name' <<<"$1")
  aws_paced ecs list-tasks --cluster "$cluster" --service-name "$service" | jq '.taskArns' | chunks 100 |
    while read -r arns; do
      # shellcheck disable=SC2086
      aws_paced ecs describe-tasks --cluster "$cluster" --tasks $arns | jq -c '.tasks[]' || exit 1
    done | jq -s -c "$jq_lib"'map({
      task_arn: .taskArn,
      task_definition: .taskDefinitionArn,
      last_status: .lastStatus,
      desired_status: .desiredStatus,
      health_status: .healthStatus,
      launch_type: .launchType,
      container_instance_arn: .containerInstanceArn,
      availability_zone: .availabilityZone,
      started_at: (.startedAt | utc_iso)
    })'
}

run_main "$@"
