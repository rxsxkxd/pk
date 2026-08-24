#!/usr/bin/env ruby
# frozen_string_literal: true

# ECS のサービスとコンテナインスタンスを 1 件 1 行の JSONL で出力する
#
# API 呼び出しは ListClusters と、クラスターごとの ListServices / ListContainerInstances（ページ分）、
# それを 10 件（サービス）・100 件（コンテナインスタンス）ずつまとめた Describe 系、
# 使われているタスク定義ごとの DescribeTaskDefinition だけ。出力の項目は ../README.md を参照。

require "json"
require "time"
require "aws-sdk-ecs"

module EcsInventory
  module_function

  def run(client: Aws::ECS::Client.new, out: $stdout)
    clusters = client.list_clusters.flat_map(&:cluster_arns)
    services = clusters.flat_map { |cluster| describe_services(client, cluster) }
    instances = clusters.flat_map { |cluster| describe_container_instances(client, cluster) }
    task_definitions = services.map(&:task_definition).uniq.to_h { |arn| [arn, fetch_task_definition(client, arn)] }

    services.each do |service|
      out.puts JSON.generate(service_record(service, *task_definitions[service.task_definition]))
    end
    instances.each do |cluster, instance|
      out.puts JSON.generate(container_instance_record(cluster, instance))
    end
  end

  def describe_services(client, cluster)
    arns = client.list_services(cluster: cluster).flat_map(&:service_arns)
    arns.each_slice(10).flat_map { |chunk| client.describe_services(cluster: cluster, services: chunk).services }
  end

  # コンテナインスタンスの応答にはクラスターが入っていないので、組にして返す
  def describe_container_instances(client, cluster)
    arns = client.list_container_instances(cluster: cluster).flat_map(&:container_instance_arns)
    arns.each_slice(100).flat_map do |chunk|
      client.describe_container_instances(cluster: cluster, container_instances: chunk).container_instances
    end.map { |instance| [cluster, instance] }
  end

  # 取れなかったタスク定義は、そのサービスの errors に記録して続ける
  def fetch_task_definition(client, arn)
    [client.describe_task_definition(task_definition: arn).task_definition, nil]
  rescue Aws::ECS::Errors::ServiceError => e
    [nil, { "operation" => "DescribeTaskDefinition", "code" => e.code, "message" => e.message }]
  end

  def service_record(service, task_definition, error)
    td = task_definition
    awsvpc = service.network_configuration&.awsvpc_configuration
    breaker = service.deployment_configuration&.deployment_circuit_breaker
    {
      "record_type" => "service",
      "cluster_name" => cluster_name(service.cluster_arn),
      "service_name" => service.service_name,
      "service_arn" => service.service_arn,
      "status" => service.status,
      "launch_type" => service.launch_type,
      "capacity_provider_strategy" => (service.capacity_provider_strategy || []).map do |s|
        { "capacity_provider" => s.capacity_provider, "weight" => s.weight, "base" => s.base }
      end,
      "platform_version" => service.platform_version,
      "platform_family" => service.platform_family,
      "scheduling_strategy" => service.scheduling_strategy,
      "desired_count" => service.desired_count,
      "running_count" => service.running_count,
      "pending_count" => service.pending_count,
      "task_definition" => service.task_definition,
      "cpu" => td&.cpu,
      "memory" => td&.memory,
      "os_family" => td&.runtime_platform&.operating_system_family,
      "cpu_architecture" => td&.runtime_platform&.cpu_architecture,
      "network_mode" => td&.network_mode,
      "requires_compatibilities" => td&.requires_compatibilities || [],
      "task_role_arn" => td&.task_role_arn,
      "execution_role_arn" => td&.execution_role_arn,
      "containers" => (td&.container_definitions || []).map { |c| container(c) },
      "load_balancers" => (service.load_balancers || []).map do |lb|
        {
          "target_group_arn" => lb.target_group_arn,
          "load_balancer_name" => lb.load_balancer_name,
          "container_name" => lb.container_name,
          "container_port" => lb.container_port,
        }
      end,
      "service_registries" => (service.service_registries || []).map(&:registry_arn),
      "network" => awsvpc && {
        "subnets" => awsvpc.subnets || [],
        "security_groups" => awsvpc.security_groups || [],
        "assign_public_ip" => awsvpc.assign_public_ip,
      },
      "deployment_circuit_breaker" => breaker && { "enable" => breaker.enable, "rollback" => breaker.rollback },
      "enable_execute_command" => service.enable_execute_command,
      "created_at" => utc_iso(service.created_at),
      "errors" => [error].compact,
    }
  end

  def container(definition)
    {
      "name" => definition.name,
      "image" => definition.image,
      "essential" => definition.essential,
      "cpu" => definition.cpu,
      "memory" => definition.memory,
      "memory_reservation" => definition.memory_reservation,
      "port_mappings" => (definition.port_mappings || []).map do |pm|
        { "container_port" => pm.container_port, "host_port" => pm.host_port, "protocol" => pm.protocol }
      end,
      "log_driver" => definition.log_configuration&.log_driver,
    }
  end

  def container_instance_record(cluster, instance)
    attributes = (instance.attributes || []).to_h { |a| [a.name, a.value] }
    {
      "record_type" => "container_instance",
      "cluster_name" => cluster_name(cluster),
      "container_instance_arn" => instance.container_instance_arn,
      "ec2_instance_id" => instance.ec2_instance_id,
      "status" => instance.status,
      "agent_connected" => instance.agent_connected,
      "agent_version" => instance.version_info&.agent_version,
      "docker_version" => instance.version_info&.docker_version,
      "os_type" => attributes["ecs.os-type"],
      "os_family" => attributes["ecs.os-family"],
      "cpu_architecture" => attributes["ecs.cpu-architecture"],
      "ami_id" => attributes["ecs.ami-id"],
      "instance_type" => attributes["ecs.instance-type"],
      "capacity_provider_name" => instance.capacity_provider_name,
      "running_tasks_count" => instance.running_tasks_count,
      "pending_tasks_count" => instance.pending_tasks_count,
      "registered_at" => utc_iso(instance.registered_at),
      "errors" => [],
    }
  end

  def cluster_name(arn) = arn.split("/").last

  def utc_iso(time) = time&.getutc&.iso8601
end

EcsInventory.run if $PROGRAM_NAME == __FILE__
