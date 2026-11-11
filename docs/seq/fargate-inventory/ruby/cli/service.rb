# frozen_string_literal: true

# Fargate で動いているタスクの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "fargate_inventory.rb"
  SNAPSHOT_OPTIONS = { "--cluster" => "対象のクラスター（名前か ARN）。指定しなければすべてのクラスター" }.freeze

  module_function

  def snapshot(ctx, opts)
    clusters = opts["cluster"].empty? ? ctx.call("ecs", "list_clusters")["clusterArns"] : opts["cluster"]
    # 動いている（RUNNING を目指している）Fargate のタスクを、クラスターごとに 100 件ずつまとめて引く
    clusters.flat_map do |cluster|
      arns = ctx.call("ecs", "list_tasks", { "cluster" => cluster, "launchType" => "FARGATE" })["taskArns"]
      arns.each_slice(100).flat_map do |chunk|
        ctx.call("ecs", "describe_tasks", { "cluster" => cluster, "tasks" => chunk, "include" => ["TAGS"] })["tasks"]
      end
    end.map { |t| task_record(ctx, t) }
  end

  def eni_detail(task, name)
    (task["attachments"] || []).select { |a| a["type"] == "ElasticNetworkInterface" }
                               .flat_map { |a| a["details"] || [] }
                               .find { |d| d["name"] == name }&.dig("value")
  end

  def task_record(ctx, t)
    group = t["group"] || ""
    ctx.record("fargate_task", {
      "cluster_name" => t["clusterArn"].split("/").last,
      "task_arn" => t["taskArn"],
      "task_definition" => t["taskDefinitionArn"],
      "group" => t["group"],
      "service_name" => group.start_with?("service:") ? group.delete_prefix("service:") : nil,
      "started_by" => t["startedBy"],
      "last_status" => t["lastStatus"],
      "desired_status" => t["desiredStatus"],
      "health_status" => t["healthStatus"],
      "capacity_provider_name" => t["capacityProviderName"],
      "platform_version" => t["platformVersion"],
      "platform_family" => t["platformFamily"],
      "cpu" => t["cpu"],
      "memory" => t["memory"],
      "ephemeral_storage_gib" => t.dig("ephemeralStorage", "sizeInGiB"),
      "availability_zone" => t["availabilityZone"],
      "subnet_id" => eni_detail(t, "subnetId"),
      "private_ipv4_address" => eni_detail(t, "privateIPv4Address"),
      "network_interface_id" => eni_detail(t, "networkInterfaceId"),
      "enable_execute_command" => t["enableExecuteCommand"],
      "started_at" => InventoryCommon.utc_iso(t["startedAt"]),
      "tags" => InventoryCommon.tags_object(t["tags"]),
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

  DETAIL_KINDS = {
    "task_definition" => [%w[fargate_task], :task_definition],
  }.freeze
end
