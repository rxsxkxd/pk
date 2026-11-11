# frozen_string_literal: true

# ECS のサービスとコンテナインスタンスの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-ecs"

module Service
  TOOL = "ecs_inventory.rb"
  SNAPSHOT_OPTIONS = { "--cluster" => "対象のクラスター（名前か ARN）。指定しなければすべてのクラスター" }.freeze

  module_function

  def cluster_name(arn) = arn.split("/").last

  def snapshot(ctx, opts)
    ecs = ctx.client(:ECS)
    clusters = opts["cluster"].empty? ? ecs.list_clusters.flat_map(&:cluster_arns) : opts["cluster"]
    services = []
    instances = []
    clusters.each do |cluster|
      ecs.list_services(cluster: cluster).flat_map(&:service_arns).each_slice(10) do |chunk|
        services += ecs.describe_services(cluster: cluster, services: chunk, include: ["TAGS"]).services
      end
      # コンテナインスタンスの応答にはクラスターが入っていないので、クラスターと組にしておく
      ecs.list_container_instances(cluster: cluster).flat_map(&:container_instance_arns).each_slice(100) do |chunk|
        instances += ecs.describe_container_instances(cluster: cluster, container_instances: chunk)
                        .container_instances.map { |ci| [cluster, ci] }
      end
    end
    services.map { |s| service_record(ctx, s) } + instances.map { |cluster, ci| container_instance_record(ctx, cluster, ci) }
  end

  def service_record(ctx, s)
    awsvpc = s.network_configuration&.awsvpc_configuration
    breaker = s.deployment_configuration&.deployment_circuit_breaker
    ctx.record("ecs_service", {
      "cluster_name" => cluster_name(s.cluster_arn),
      "service_name" => s.service_name,
      "service_arn" => s.service_arn,
      "status" => s.status,
      "launch_type" => s.launch_type,
      "capacity_provider_strategy" => (s.capacity_provider_strategy || []).map do |p|
        { "capacity_provider" => p.capacity_provider, "weight" => p.weight, "base" => p.base }
      end,
      "platform_version" => s.platform_version,
      "platform_family" => s.platform_family,
      "scheduling_strategy" => s.scheduling_strategy,
      "desired_count" => s.desired_count,
      "running_count" => s.running_count,
      "pending_count" => s.pending_count,
      "task_definition" => s.task_definition,
      "load_balancers" => (s.load_balancers || []).map do |lb|
        {
          "target_group_arn" => lb.target_group_arn,
          "load_balancer_name" => lb.load_balancer_name,
          "container_name" => lb.container_name,
          "container_port" => lb.container_port,
        }
      end,
      "service_registries" => (s.service_registries || []).map(&:registry_arn),
      "network" => awsvpc && {
        "subnets" => awsvpc.subnets || [],
        "security_groups" => awsvpc.security_groups || [],
        "assign_public_ip" => awsvpc.assign_public_ip,
      },
      "deployment_circuit_breaker" => breaker && { "enable" => breaker.enable, "rollback" => breaker.rollback },
      "enable_execute_command" => s.enable_execute_command,
      "created_at" => InventoryCommon.utc_iso(s.created_at),
      "tags" => InventoryCommon.tags_object(s.tags),
    })
  end

  def container_instance_record(ctx, cluster, ci)
    attributes = (ci.attributes || []).to_h { |a| [a.name, a.value] }
    ctx.record("ecs_container_instance", {
      "cluster_name" => cluster_name(cluster),
      "container_instance_arn" => ci.container_instance_arn,
      "ec2_instance_id" => ci.ec2_instance_id,
      "status" => ci.status,
      "agent_connected" => ci.agent_connected,
      "agent_version" => ci.version_info&.agent_version,
      "docker_version" => ci.version_info&.docker_version,
      "os_type" => attributes["ecs.os-type"],
      "os_family" => attributes["ecs.os-family"],
      "cpu_architecture" => attributes["ecs.cpu-architecture"],
      "ami_id" => attributes["ecs.ami-id"],
      "instance_type" => attributes["ecs.instance-type"],
      "capacity_provider_name" => ci.capacity_provider_name,
      "running_tasks_count" => ci.running_tasks_count,
      "pending_tasks_count" => ci.pending_tasks_count,
      "registered_at" => InventoryCommon.utc_iso(ci.registered_at),
    })
  end

  # タスク定義の要約。同じタスク定義は 1 回だけ引く
  def task_definition(ctx, record)
    arn = record["task_definition"]
    td = ctx.cached([:td, arn]) { ctx.pace { ctx.client(:ECS).describe_task_definition(task_definition: arn).task_definition } }
    {
      "family" => td.family,
      "revision" => td.revision,
      "status" => td.status,
      "cpu" => td.cpu,
      "memory" => td.memory,
      "os_family" => td.runtime_platform&.operating_system_family,
      "cpu_architecture" => td.runtime_platform&.cpu_architecture,
      "network_mode" => td.network_mode,
      "requires_compatibilities" => td.requires_compatibilities || [],
      "task_role_arn" => td.task_role_arn,
      "execution_role_arn" => td.execution_role_arn,
      "containers" => (td.container_definitions || []).map do |c|
        {
          "name" => c.name,
          "image" => c.image,
          "essential" => c.essential,
          "cpu" => c.cpu,
          "memory" => c.memory,
          "memory_reservation" => c.memory_reservation,
          "port_mappings" => (c.port_mappings || []).map do |pm|
            { "container_port" => pm.container_port, "host_port" => pm.host_port, "protocol" => pm.protocol }
          end,
          "log_driver" => c.log_configuration&.log_driver,
        }
      end,
    }
  end

  # サービスのタスクと、それが動いているホスト
  def tasks(ctx, record)
    ecs = ctx.client(:ECS)
    cluster = record["cluster_name"]
    arns = ctx.pace { ecs.list_tasks(cluster: cluster, service_name: record["service_name"]).flat_map(&:task_arns) }
    arns.each_slice(100).flat_map do |chunk|
      ctx.pace { ecs.describe_tasks(cluster: cluster, tasks: chunk).tasks }.map do |t|
        {
          "task_arn" => t.task_arn,
          "task_definition" => t.task_definition_arn,
          "last_status" => t.last_status,
          "desired_status" => t.desired_status,
          "health_status" => t.health_status,
          "launch_type" => t.launch_type,
          "container_instance_arn" => t.container_instance_arn,
          "availability_zone" => t.availability_zone,
          "started_at" => InventoryCommon.utc_iso(t.started_at),
        }
      end
    end
  end

  DETAIL_KINDS = {
    "task_definition" => [%w[ecs_service], :task_definition],
    "tasks" => [%w[ecs_service], :tasks],
  }.freeze
end
