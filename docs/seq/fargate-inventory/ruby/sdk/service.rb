# frozen_string_literal: true

# Fargate で動いているタスクの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-ecs"

module Service
  TOOL = "fargate_inventory.rb"
  SNAPSHOT_OPTIONS = { "--cluster" => "対象のクラスター（名前か ARN）。指定しなければすべてのクラスター" }.freeze

  module_function

  def snapshot(ctx, opts)
    ecs = ctx.client(:ECS)
    clusters = opts["cluster"].empty? ? ecs.list_clusters.flat_map(&:cluster_arns) : opts["cluster"]
    # 動いている（RUNNING を目指している）Fargate のタスクを、クラスターごとに 100 件ずつまとめて引く
    clusters.flat_map do |cluster|
      arns = ecs.list_tasks(cluster: cluster, launch_type: "FARGATE").flat_map(&:task_arns)
      arns.each_slice(100).flat_map { |chunk| ecs.describe_tasks(cluster: cluster, tasks: chunk, include: ["TAGS"]).tasks }
    end.map { |t| task_record(ctx, t) }
  end

  def eni_detail(task, name)
    (task.attachments || []).select { |a| a.type == "ElasticNetworkInterface" }
                            .flat_map { |a| a.details || [] }
                            .find { |d| d.name == name }&.value
  end

  def task_record(ctx, t)
    group = t.group || ""
    ctx.record("fargate_task", {
      "cluster_name" => t.cluster_arn.split("/").last,
      "task_arn" => t.task_arn,
      "task_definition" => t.task_definition_arn,
      "group" => t.group,
      "service_name" => group.start_with?("service:") ? group.delete_prefix("service:") : nil,
      "started_by" => t.started_by,
      "last_status" => t.last_status,
      "desired_status" => t.desired_status,
      "health_status" => t.health_status,
      "capacity_provider_name" => t.capacity_provider_name,
      "platform_version" => t.platform_version,
      "platform_family" => t.platform_family,
      "cpu" => t.cpu,
      "memory" => t.memory,
      "ephemeral_storage_gib" => t.ephemeral_storage&.size_in_gi_b,
      "availability_zone" => t.availability_zone,
      "subnet_id" => eni_detail(t, "subnetId"),
      "private_ipv4_address" => eni_detail(t, "privateIPv4Address"),
      "network_interface_id" => eni_detail(t, "networkInterfaceId"),
      "enable_execute_command" => t.enable_execute_command,
      "started_at" => InventoryCommon.utc_iso(t.started_at),
      "tags" => InventoryCommon.tags_object(t.tags),
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

  DETAIL_KINDS = {
    "task_definition" => [%w[fargate_task], :task_definition],
  }.freeze
end
