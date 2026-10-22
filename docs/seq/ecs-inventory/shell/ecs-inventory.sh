#!/usr/bin/env bash
# ECS のサービスとコンテナインスタンスを 1 件 1 行の JSONL で出力する
#
# API 呼び出しは ListClusters と、クラスターごとの ListServices / ListContainerInstances（ページ分）、
# それを 10 件（サービス）・100 件（コンテナインスタンス）ずつまとめた Describe 系、
# 使われているタスク定義ごとの DescribeTaskDefinition だけ。出力の項目は ../README.md を参照。
set -euo pipefail

for cmd in aws jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd が必要です" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# CLI のエラー文から 操作名・コード・本文 を取り出す（$1: 取り出せないときの操作名, $2: stderr のファイル）
cli_error() {
  jq -nc --arg op "$1" --arg err "$(<"$2")" '
    ($err | capture("\\((?<code>[^)]+)\\) when calling the (?<operation>[A-Za-z]+) operation: (?<message>.*)"))
      // {operation: $op, code: "Unknown", message: $err}
    | {operation, code, message}'
}

# 配列を n 件ずつ空白区切りの 1 行にする
chunks() {
  jq -r --argjson n "$1" ". as \$a | range(0; length; \$n) | \$a[.:. + \$n] | join(\" \")"
}

aws ecs list-clusters --output json | jq -r '.clusterArns[]' >"$work/clusters.txt"

: >"$work/services.jsonl"
: >"$work/container-instances.jsonl"
while read -r cluster; do
  aws ecs list-services --cluster "$cluster" --output json </dev/null | jq '.serviceArns' | chunks 10 |
    while read -r arns; do
      # shellcheck disable=SC2086 # ARN を別々の引数として渡す
      aws ecs describe-services --cluster "$cluster" --services $arns --output json </dev/null | jq -c '.services[]'
    done >>"$work/services.jsonl"

  # コンテナインスタンスの応答にはクラスターが入っていないので足しておく
  aws ecs list-container-instances --cluster "$cluster" --output json </dev/null | jq '.containerInstanceArns' | chunks 100 |
    while read -r arns; do
      # shellcheck disable=SC2086
      aws ecs describe-container-instances --cluster "$cluster" --container-instances $arns --output json </dev/null |
        jq -c --arg cluster "$cluster" '.containerInstances[] | . + {clusterArn: $cluster}'
    done >>"$work/container-instances.jsonl"
done <"$work/clusters.txt"

# タスク定義は、サービスが使っているものだけを 1 回ずつ引く。
# 取れなかったものは、そのサービスの errors に記録して続ける
jq -r '.taskDefinition' "$work/services.jsonl" | sort -u |
  while read -r arn; do
    if aws ecs describe-task-definition --task-definition "$arn" --output json >"$work/td.json" 2>"$work/err" </dev/null; then
      jq -c --arg arn "$arn" '{arn: $arn, task_definition: .taskDefinition, error: null}' "$work/td.json"
    else
      jq -nc --arg arn "$arn" --argjson error "$(cli_error DescribeTaskDefinition "$work/err")" \
        '{arn: $arn, task_definition: null, error: $error}'
    fi
  done >"$work/task-definitions.jsonl"

jq -c -n \
  --slurpfile services "$work/services.jsonl" \
  --slurpfile instances "$work/container-instances.jsonl" \
  --slurpfile task_definitions "$work/task-definitions.jsonl" '
  # CLI の日時（ISO 8601 のタイムゾーン付き、または設定によってはエポック秒）を UTC の秒単位にそろえる
  def utc_iso:
    if . == null then null
    elif type == "number" then floor | todate
    else
      (capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$") // null) as $m
      | if $m == null then .
        else
          ($m.tz | if . == "Z" then 0
                   else (if startswith("-") then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)
                   end) as $offset
          | ($m.dt + "Z" | fromdateiso8601) - $offset | todate
        end
    end;

  def cluster_name: split("/")[-1];

  def attribute($name): first(.attributes[]? | select(.name == $name) | .value) // null;

  def container:
    {
      name,
      image,
      essential,
      cpu,
      memory,
      memory_reservation: .memoryReservation,
      port_mappings: [.portMappings[]? | {container_port: .containerPort, host_port: .hostPort, protocol}],
      log_driver: .logConfiguration.logDriver,
      environment_variable_keys: ([.environment[]?.name] | sort),
      secret_names: ([.secrets[]?.name] | sort)
    };

  ($task_definitions | map({key: .arn, value: .}) | from_entries) as $td_by_arn
  | (
      $services[]
      | $td_by_arn[.taskDefinition] as $entry
      | ($entry.task_definition // {}) as $td
      | {
          record_type: "service",
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
          cpu: $td.cpu,
          memory: $td.memory,
          os_family: $td.runtimePlatform.operatingSystemFamily,
          cpu_architecture: $td.runtimePlatform.cpuArchitecture,
          network_mode: $td.networkMode,
          requires_compatibilities: ($td.requiresCompatibilities // []),
          task_role_arn: $td.taskRoleArn,
          execution_role_arn: $td.executionRoleArn,
          containers: [$td.containerDefinitions[]? | container],
          load_balancers: [
            .loadBalancers[]?
            | {
                target_group_arn: .targetGroupArn,
                load_balancer_name: .loadBalancerName,
                container_name: .containerName,
                container_port: .containerPort
              }
          ],
          service_registries: [.serviceRegistries[]?.registryArn],
          network: (
            .networkConfiguration.awsvpcConfiguration
            | if . == null then null
              else {subnets: (.subnets // []), security_groups: (.securityGroups // []), assign_public_ip: .assignPublicIp}
              end
          ),
          deployment_circuit_breaker: (
            .deploymentConfiguration.deploymentCircuitBreaker
            | if . == null then null else {enable, rollback} end
          ),
          enable_execute_command: .enableExecuteCommand,
          created_at: (.createdAt | utc_iso),
          errors: [$entry.error | select(. != null)]
        }
    ),
    (
      $instances[]
      | {
          record_type: "container_instance",
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
          registered_at: (.registeredAt | utc_iso),
          errors: []
        }
    )'
