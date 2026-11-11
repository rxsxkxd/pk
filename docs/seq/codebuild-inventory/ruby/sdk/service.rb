# frozen_string_literal: true

# CodeBuild プロジェクトの棚卸し（Ruby SDK 版の service）。出力の項目は ../../DATA.md を参照。

require "aws-sdk-codebuild"

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
    codebuild = ctx.client(:CodeBuild)
    # プロジェクト名を 100 件ずつまとめて定義を引く
    codebuild.list_projects.flat_map(&:projects).each_slice(100).flat_map do |chunk|
      codebuild.batch_get_projects(names: chunk).projects
    end.map { |p| project_record(ctx, p) }
  end

  def project_record(ctx, p)
    env = p.environment
    vpc = p.vpc_config
    ctx.record("codebuild_project", {
      "project_name" => p.name,
      "project_arn" => p.arn,
      "description" => p.description,
      "environment_type" => env&.type,
      "image" => env&.image,
      "base_os" => os_from_image(env&.image),
      "compute_type" => env&.compute_type,
      "privileged_mode" => env&.privileged_mode,
      "image_pull_credentials_type" => env&.image_pull_credentials_type,
      "service_role" => p.service_role,
      "source_type" => p.source&.type,
      "source_location" => p.source&.location,
      "source_version" => p.source_version,
      "webhook" => p.webhook && {
        "build_type" => p.webhook.build_type,
        "filter_group_count" => (p.webhook.filter_groups || []).size,
      },
      "vpc" => vpc.nil? || vpc.vpc_id.to_s.empty? ? nil : {
        "vpc_id" => vpc.vpc_id,
        "subnets" => vpc.subnets || [],
        "security_group_ids" => vpc.security_group_ids || [],
      },
      "timeout_in_minutes" => p.timeout_in_minutes,
      "queued_timeout_in_minutes" => p.queued_timeout_in_minutes,
      "concurrent_build_limit" => p.concurrent_build_limit,
      "artifacts_type" => p.artifacts&.type,
      "cache_type" => p.cache&.type,
      "cloudwatch_logs" => p.logs_config&.cloud_watch_logs&.status,
      "s3_logs" => p.logs_config&.s3_logs&.status,
      "encryption_key" => p.encryption_key,
      "created_at" => InventoryCommon.utc_iso(p.created),
      "last_modified_at" => InventoryCommon.utc_iso(p.last_modified),
      "tags" => InventoryCommon.tags_object(p.tags),
    })
  end

  # 直近のビルド。ビルドが 1 度も無ければ nil。履歴は 1 ページ目だけを取る
  def last_build(ctx, record)
    codebuild = ctx.client(:CodeBuild)
    ids = ctx.pace { codebuild.list_builds_for_project(project_name: record["project_name"], sort_order: "DESCENDING").ids } || []
    return nil if ids.empty?

    b = ctx.pace { codebuild.batch_get_builds(ids: ids.first(1)).builds.first }
    {
      "build_id" => b.id,
      "status" => b.build_status,
      "current_phase" => b.current_phase,
      "start_time" => InventoryCommon.utc_iso(b.start_time),
      "end_time" => InventoryCommon.utc_iso(b.end_time),
      "source_version" => b.source_version,
      "resolved_source_version" => b.resolved_source_version,
      "initiator" => b.initiator,
    }
  end

  DETAIL_KINDS = {
    "last_build" => [%w[codebuild_project], :last_build],
  }.freeze
end
