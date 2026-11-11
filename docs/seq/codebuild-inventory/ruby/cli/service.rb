# frozen_string_literal: true

# CodeBuild プロジェクトの棚卸し（Ruby CLI 版の service）。出力の項目は ../../DATA.md を参照。

module Service
  TOOL = "codebuild_inventory.rb"
  SNAPSHOT_OPTIONS = {}.freeze
  IMAGES = JSON.parse(File.read(File.join(__dir__, "codebuild-image-os.json")))

  module_function

  # CodeBuild が提供するイメージは名前から OS がわかる。自前のイメージ（ECR など）はわからない
  def os_from_image(image)
    return nil if image.nil?

    hit = IMAGES.find { |p| Regexp.new(p["pattern"]).match?(image) }
    return hit["os"] if hit

    image.start_with?("aws/codebuild/") ? "Unknown" : "Custom Image"
  end

  def snapshot(ctx, _opts)
    # プロジェクト名を 100 件ずつまとめて定義を引く
    ctx.call("codebuild", "list_projects")["projects"].each_slice(100).flat_map do |chunk|
      ctx.call("codebuild", "batch_get_projects", { "names" => chunk })["projects"]
    end.map { |p| project_record(ctx, p) }
  end

  def project_record(ctx, p)
    env = p["environment"] || {}
    vpc = p["vpcConfig"]
    webhook = p["webhook"]
    ctx.record("codebuild_project", {
      "project_name" => p["name"],
      "project_arn" => p["arn"],
      "description" => p["description"],
      "environment_type" => env["type"],
      "image" => env["image"],
      "base_os" => os_from_image(env["image"]),
      "compute_type" => env["computeType"],
      "privileged_mode" => env["privilegedMode"],
      "image_pull_credentials_type" => env["imagePullCredentialsType"],
      "service_role" => p["serviceRole"],
      "source_type" => p.dig("source", "type"),
      "source_location" => p.dig("source", "location"),
      "source_version" => p["sourceVersion"],
      "webhook" => webhook && {
        "build_type" => webhook["buildType"],
        "filter_group_count" => (webhook["filterGroups"] || []).size,
      },
      "vpc" => vpc.nil? || vpc["vpcId"].to_s.empty? ? nil : {
        "vpc_id" => vpc["vpcId"],
        "subnets" => vpc["subnets"] || [],
        "security_group_ids" => vpc["securityGroupIds"] || [],
      },
      "timeout_in_minutes" => p["timeoutInMinutes"],
      "queued_timeout_in_minutes" => p["queuedTimeoutInMinutes"],
      "concurrent_build_limit" => p["concurrentBuildLimit"],
      "artifacts_type" => p.dig("artifacts", "type"),
      "cache_type" => p.dig("cache", "type"),
      "cloudwatch_logs" => p.dig("logsConfig", "cloudWatchLogs", "status"),
      "s3_logs" => p.dig("logsConfig", "s3Logs", "status"),
      "encryption_key" => p["encryptionKey"],
      "created_at" => InventoryCommon.utc_iso(p["created"]),
      "last_modified_at" => InventoryCommon.utc_iso(p["lastModified"]),
      "tags" => InventoryCommon.tags_object(p["tags"]),
    })
  end

  # 直近のビルド。ビルドが 1 度も無ければ nil。履歴は 1 ページ目だけを取る
  def last_build(ctx, record)
    params = { "projectName" => record["project_name"], "sortOrder" => "DESCENDING" }
    ids = ctx.call("codebuild", "list_builds_for_project", params, paginate: false)["ids"] || []
    return nil if ids.empty?

    b = ctx.call("codebuild", "batch_get_builds", { "ids" => ids.first(1) })["builds"].first
    {
      "build_id" => b["id"],
      "status" => b["buildStatus"],
      "current_phase" => b["currentPhase"],
      "start_time" => InventoryCommon.utc_iso(b["startTime"]),
      "end_time" => InventoryCommon.utc_iso(b["endTime"]),
      "source_version" => b["sourceVersion"],
      "resolved_source_version" => b["resolvedSourceVersion"],
      "initiator" => b["initiator"],
    }
  end

  DETAIL_KINDS = {
    "last_build" => [%w[codebuild_project], :last_build],
  }.freeze
end
