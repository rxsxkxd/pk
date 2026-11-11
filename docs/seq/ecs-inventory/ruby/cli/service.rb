# frozen_string_literal: true

# ECS のサービスとコンテナインスタンスの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "ecs_inventory.rb"
  SNAPSHOT_OPTIONS = { "--cluster" => "対象のクラスター（名前か ARN）。指定しなければすべてのクラスター" }.freeze

  module_function

  def cluster_name(arn) = arn.split("/").last

  def snapshot(ctx, opts)
    clusters = opts["cluster"].empty? ? ctx.call("ecs", "list_clusters")["clusterArns"] : opts["cluster"]
    services = []
    instances = []
    clusters.each do |cluster|
      ctx.call("ecs", "list_services", { "cluster" => cluster })["serviceArns"].each_slice(10) do |chunk|
        services += ctx.call("ecs", "describe_services",
                             { "cluster" => cluster, "services" => chunk, "include" => ["TAGS"] })["services"]
      end
      # コンテナインスタンスの応答にはクラスターが入っていないので、クラスターと組にしておく
      ctx.call("ecs", "list_container_instances", { "cluster" => cluster })["containerInstanceArns"].each_slice(100) do |chunk|
        cis = ctx.call("ecs", "describe_container_instances",
                       { "cluster" => cluster, "containerInstances" => chunk })["containerInstances"]
        instances += cis.map { |ci| [cluster, ci] }
      end
    end
    services.map { |s| service_record(ctx, s) } + instances.map { |cluster, ci| container_instance_record(ctx, cluster, ci) }
  end

  def service_record(ctx, s)
    awsvpc = s.dig("networkConfiguration", "awsvpcConfiguration")
    breaker = s.dig("deploymentConfiguration", "deploymentCircuitBreaker")
    ctx.record("ecs_service", {
      "cluster_name" => cluster_name(s["clusterArn"]),
      "service_name" => s["serviceName"],
      "service_arn" => s["serviceArn"],
      "status" => s["status"],
      "launch_type" => s["launchType"],
      "capacity_provider_strategy" => (s["capacityProviderStrategy"] || []).map do |p|
        { "capacity_provider" => p["capacityProvider"], "weight" => p["weight"], "base" => p["base"] }
      end,
      "platform_version" => s["platformVersion"],
      "platform_family" => s["platformFamily"],
      "scheduling_strategy" => s["schedulingStrategy"],
      "desired_count" => s["desiredCount"],
      "running_count" => s["runningCount"],
      "pending_count" => s["pendingCount"],
      "task_definition" => s["taskDefinition"],
      "load_balancers" => (s["loadBalancers"] || []).map do |lb|
        {
          "target_group_arn" => lb["targetGroupArn"],
          "load_balancer_name" => lb["loadBalancerName"],
          "container_name" => lb["containerName"],
          "container_port" => lb["containerPort"],
        }
      end,
      "service_registries" => (s["serviceRegistries"] || []).map { |r| r["registryArn"] },
      "network" => awsvpc && {
        "subnets" => awsvpc["subnets"] || [],
        "security_groups" => awsvpc["securityGroups"] || [],
        "assign_public_ip" => awsvpc["assignPublicIp"],
      },
      "deployment_circuit_breaker" => breaker && { "enable" => breaker["enable"], "rollback" => breaker["rollback"] },
      "enable_execute_command" => s["enableExecuteCommand"],
      "created_at" => InventoryCommon.utc_iso(s["createdAt"]),
      "tags" => InventoryCommon.tags_object(s["tags"]),
    })
  end

  def container_instance_record(ctx, cluster, ci)
    attributes = (ci["attributes"] || []).to_h { |a| [a["name"], a["value"]] }
    ctx.record("ecs_container_instance", {
      "cluster_name" => cluster_name(cluster),
      "container_instance_arn" => ci["containerInstanceArn"],
      "ec2_instance_id" => ci["ec2InstanceId"],
      "status" => ci["status"],
      "agent_connected" => ci["agentConnected"],
      "agent_version" => ci.dig("versionInfo", "agentVersion"),
      "docker_version" => ci.dig("versionInfo", "dockerVersion"),
      "os_type" => attributes["ecs.os-type"],
      "os_family" => attributes["ecs.os-family"],
      "cpu_architecture" => attributes["ecs.cpu-architecture"],
      "ami_id" => attributes["ecs.ami-id"],
      "instance_type" => attributes["ecs.instance-type"],
      "capacity_provider_name" => ci["capacityProviderName"],
      "running_tasks_count" => ci["runningTasksCount"],
      "pending_tasks_count" => ci["pendingTasksCount"],
      "registered_at" => InventoryCommon.utc_iso(ci["registeredAt"]),
    })
  end

  # タスク定義の要約。同じタスク定義は 1 回だけ引く
  def task_definition(ctx, record)
    arn = record["task_definition"]
    td = ctx.cached([:td, arn]) { ctx.call("ecs", "describe_task_definition", { "taskDefinition" => arn })["taskDefinition"] }
    {
      "family" => td["family"],
      "revision" => td["revision"],
      "status" => td["status"],
      "cpu" => td["cpu"],
      "memory" => td["memory"],
      "os_family" => td.dig("runtimePlatform", "operatingSystemFamily"),
      "cpu_architecture" => td.dig("runtimePlatform", "cpuArchitecture"),
      "network_mode" => td["networkMode"],
      "requires_compatibilities" => td["requiresCompatibilities"] || [],
      "task_role_arn" => td["taskRoleArn"],
      "execution_role_arn" => td["executionRoleArn"],
      "containers" => (td["containerDefinitions"] || []).map do |c|
        {
          "name" => c["name"],
          "image" => c["image"],
          "essential" => c["essential"],
          "cpu" => c["cpu"],
          "memory" => c["memory"],
          "memory_reservation" => c["memoryReservation"],
          "port_mappings" => (c["portMappings"] || []).map do |pm|
            { "container_port" => pm["containerPort"], "host_port" => pm["hostPort"], "protocol" => pm["protocol"] }
          end,
          "log_driver" => c.dig("logConfiguration", "logDriver"),
        }
      end,
    }
  end

  # サービスのタスクと、それが動いているホスト
  def tasks(ctx, record)
    cluster = record["cluster_name"]
    arns = ctx.call("ecs", "list_tasks", { "cluster" => cluster, "serviceName" => record["service_name"] })["taskArns"]
    arns.each_slice(100).flat_map do |chunk|
      ctx.call("ecs", "describe_tasks", { "cluster" => cluster, "tasks" => chunk })["tasks"].map do |t|
        {
          "task_arn" => t["taskArn"],
          "task_definition" => t["taskDefinitionArn"],
          "last_status" => t["lastStatus"],
          "desired_status" => t["desiredStatus"],
          "health_status" => t["healthStatus"],
          "launch_type" => t["launchType"],
          "container_instance_arn" => t["containerInstanceArn"],
          "availability_zone" => t["availabilityZone"],
          "started_at" => InventoryCommon.utc_iso(t["startedAt"]),
        }
      end
    end
  end

  DETAIL_KINDS = {
    "task_definition" => [%w[ecs_service], :task_definition],
    "tasks" => [%w[ecs_service], :tasks],
  }.freeze
end
