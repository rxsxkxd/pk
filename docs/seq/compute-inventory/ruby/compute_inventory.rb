#!/usr/bin/env ruby
# frozen_string_literal: true

# EC2 と ECS をまとめて棚卸しする
#
#   snapshot: まとめて取得できる API だけで一覧を取り、1 件 1 行の JSONL で出す
#   detail:   標準入力のレコード（snapshot の出力を jq で絞ったもの）に、リソースごとの詳細を足す
#
# 使い方と出力の項目は ../README.md を参照。

require "json"
require "optparse"
require "time"
require "aws-sdk-codebuild"
require "aws-sdk-ec2"
require "aws-sdk-ecs"
require "aws-sdk-elasticloadbalancingv2"
require "aws-sdk-ssm"

module ComputeInventory
  PATTERNS_PATH = File.expand_path("../ami-os-patterns.json", __dir__)
  CODEBUILD_IMAGES_PATH = File.expand_path("../codebuild-image-os.json", __dir__)
  # 終了済み（terminated）は除く
  LIVE_STATES = %w[pending running stopping stopped shutting-down].freeze
  # 混み合っているときは SDK が自分で間隔を空ける
  CLIENT_OPTIONS = { retry_mode: "adaptive" }.freeze
  DETAIL_KINDS = %w[task_definition tasks target_health].freeze

  module_function

  def error_entry(operation, error)
    { "operation" => operation, "code" => error.code, "message" => error.message }
  end

  def utc_iso(time) = time&.getutc&.iso8601

  def cluster_name(arn) = arn.split("/").last

  # ------------------------------------------------------------ snapshot

  class Snapshot
    def initialize(ec2_filters:, clusters:)
      @ec2 = Aws::EC2::Client.new(**CLIENT_OPTIONS)
      @ssm = Aws::SSM::Client.new(**CLIENT_OPTIONS)
      @ecs = Aws::ECS::Client.new(**CLIENT_OPTIONS)
      @codebuild = Aws::CodeBuild::Client.new(**CLIENT_OPTIONS)
      @ec2_filters = ec2_filters
      @clusters = clusters
      @patterns = JSON.parse(File.read(PATTERNS_PATH))
      @codebuild_images = JSON.parse(File.read(CODEBUILD_IMAGES_PATH))
    end

    def run(out)
      @common = { "region" => @ec2.config.region, "collected_at" => Time.now.utc.iso8601 }

      clusters = @clusters.empty? ? @ecs.list_clusters.flat_map(&:cluster_arns) : @clusters
      services = clusters.flat_map { |cluster| describe_services(cluster) }
      container_instances = clusters.flat_map { |cluster| describe_container_instances(cluster) }
                                    .to_h { |cluster, ci| [ci.ec2_instance_id, [cluster, ci]] }

      reservations = @ec2.describe_instances(
        filters: [{ name: "instance-state-name", values: LIVE_STATES }] + @ec2_filters,
      ).flat_map(&:reservations)
      images = fetch_images(reservations.flat_map(&:instances).map(&:image_id).uniq.sort)
      ssm_by_id, ssm_error = fetch_ssm

      reservations.each do |reservation|
        reservation.instances.each do |inst|
          out.puts JSON.generate(ec2_record(reservation.owner_id, inst, images[inst.image_id],
                                            ssm_by_id[inst.instance_id], ssm_error,
                                            container_instances[inst.instance_id]))
        end
      end
      services.each { |service| out.puts JSON.generate(service_record(service)) }
      fetch_projects.each { |project| out.puts JSON.generate(project_record(project)) }
    end

    private

    def describe_services(cluster)
      arns = @ecs.list_services(cluster: cluster).flat_map(&:service_arns)
      arns.each_slice(10).flat_map { |chunk| @ecs.describe_services(cluster: cluster, services: chunk).services }
    end

    # コンテナインスタンスの応答にはクラスターが入っていないので、組にして返す
    def describe_container_instances(cluster)
      arns = @ecs.list_container_instances(cluster: cluster).flat_map(&:container_instance_arns)
      arns.each_slice(100).flat_map do |chunk|
        @ecs.describe_container_instances(cluster: cluster, container_instances: chunk).container_instances
      end.map { |ci| [cluster, ci] }
    end

    # ID 指定だと 1 つでも登録解除済みの AMI があると全体がエラーになるので、フィルタで引く
    def fetch_images(ids)
      ids.each_slice(100).flat_map do |chunk|
        @ec2.describe_images(include_deprecated: true, filters: [{ name: "image-id", values: chunk }]).flat_map(&:images)
      end.to_h { |image| [image.image_id, image] }
    end

    # SSM が使えない（権限が無いなど）ときは、AMI 名からの推定に切り替えて続ける
    def fetch_ssm
      list = @ssm.describe_instance_information.flat_map(&:instance_information_list)
      [list.to_h { |info| [info.instance_id, info] }, nil]
    rescue Aws::SSM::Errors::ServiceError => e
      [{}, ComputeInventory.error_entry("DescribeInstanceInformation", e)]
    end

    def ec2_record(account_id, inst, image, ssm, ssm_error, container_instance)
      tags = (inst.tags || []).reject { |t| t.key == "Name" }.to_h { |t| [t.key, t.value] }
      os, os_source = base_os(inst, image, ssm)
      cluster, ci = container_instance
      {
        "record_type" => "ec2_instance",
        "account_id" => account_id,
        **@common,
        "instance_id" => inst.instance_id,
        "state" => inst.state&.name,
        "instance_type" => inst.instance_type,
        "architecture" => inst.architecture,
        "base_os" => os,
        "base_os_source" => os_source,
        "image_id" => inst.image_id,
        "launch_time" => ComputeInventory.utc_iso(inst.launch_time),
        "tags" => tags,
        "ecs" => ci && {
          "cluster_name" => ComputeInventory.cluster_name(cluster),
          "container_instance_arn" => ci.container_instance_arn,
          "status" => ci.status,
          "agent_connected" => ci.agent_connected,
          "agent_version" => ci.version_info&.agent_version,
        },
        "errors" => [ssm_error].compact,
      }
    end

    # SSM エージェントの報告 → AMI 名 → PlatformDetails の順で決める
    def base_os(inst, image, ssm)
      ssm_os = [ssm&.platform_name, ssm&.platform_version].reject { |v| v.nil? || v.empty? }.join(" ")
      return [ssm_os, "ssm"] unless ssm_os.empty?

      ami_os = image&.name && @patterns.find { |p| Regexp.new(p["pattern"]).match?(image.name) }&.fetch("os")
      return [ami_os, "ami_name"] if ami_os

      [inst.platform_details, "platform_details"]
    end

    def service_record(service)
      {
        "record_type" => "ecs_service",
        "account_id" => service.service_arn.split(":")[4],
        **@common,
        "cluster_name" => ComputeInventory.cluster_name(service.cluster_arn),
        "service_name" => service.service_name,
        "service_arn" => service.service_arn,
        "status" => service.status,
        "launch_type" => service.launch_type,
        "desired_count" => service.desired_count,
        "running_count" => service.running_count,
        "task_definition" => service.task_definition,
        "load_balancers" => (service.load_balancers || []).map do |lb|
          {
            "target_group_arn" => lb.target_group_arn,
            "container_name" => lb.container_name,
            "container_port" => lb.container_port,
          }
        end,
        "errors" => [],
      }
    end

    # プロジェクト名を 100 件ずつまとめて定義を引く
    def fetch_projects
      names = @codebuild.list_projects.flat_map(&:projects)
      names.each_slice(100).flat_map { |chunk| @codebuild.batch_get_projects(names: chunk).projects }
    end

    def project_record(project)
      env = project.environment
      vpc = project.vpc_config
      {
        "record_type" => "codebuild_project",
        "account_id" => project.arn.split(":")[4],
        **@common,
        "project_name" => project.name,
        "project_arn" => project.arn,
        "description" => project.description,
        "environment_type" => env&.type,
        "image" => env&.image,
        "base_os" => codebuild_os(env&.image),
        "compute_type" => env&.compute_type,
        "privileged_mode" => env&.privileged_mode,
        "image_pull_credentials_type" => env&.image_pull_credentials_type,
        "service_role" => project.service_role,
        "source_type" => project.source&.type,
        "source_location" => project.source&.location,
        "source_version" => project.source_version,
        "webhook" => project.webhook && {
          "build_type" => project.webhook.build_type,
          "filter_group_count" => (project.webhook.filter_groups || []).size,
        },
        "vpc" => vpc.nil? || vpc.vpc_id.to_s.empty? ? nil : {
          "vpc_id" => vpc.vpc_id,
          "subnets" => vpc.subnets || [],
          "security_group_ids" => vpc.security_group_ids || [],
        },
        "timeout_in_minutes" => project.timeout_in_minutes,
        "queued_timeout_in_minutes" => project.queued_timeout_in_minutes,
        "concurrent_build_limit" => project.concurrent_build_limit,
        "artifacts_type" => project.artifacts&.type,
        "cache_type" => project.cache&.type,
        "cloudwatch_logs" => project.logs_config&.cloud_watch_logs&.status,
        "s3_logs" => project.logs_config&.s3_logs&.status,
        "encryption_key" => project.encryption_key,
        "created_at" => ComputeInventory.utc_iso(project.created),
        "last_modified_at" => ComputeInventory.utc_iso(project.last_modified),
        "tags" => (project.tags || []).to_h { |t| [t.key, t.value] },
        "errors" => [],
      }
    end

    # CodeBuild が提供するイメージは名前から OS がわかる。自前のイメージ（ECR など）はわからない
    def codebuild_os(image)
      return nil if image.nil?

      hit = @codebuild_images.find { |p| Regexp.new(p["pattern"]).match?(image) }
      return hit["os"] if hit

      image.start_with?("aws/codebuild/") ? "Unknown" : "Custom Image"
    end
  end

  # ------------------------------------------------------------ detail

  class Detail
    APPLIES_TO = {
      "task_definition" => %w[ecs_service],
      "tasks" => %w[ecs_service],
      "target_health" => %w[ecs_service ec2_instance],
    }.freeze

    def initialize(kinds:, interval:)
      @ecs = Aws::ECS::Client.new(**CLIENT_OPTIONS)
      @elb = Aws::ElasticLoadBalancingV2::Client.new(**CLIENT_OPTIONS)
      @kinds = kinds
      @interval = interval
      @cache = {}
    end

    def enrich(record)
      details = {}
      errors = []
      @kinds.each do |kind|
        next unless APPLIES_TO.fetch(kind).include?(record["record_type"])

        begin
          details[kind] = send(kind, record)
        rescue Aws::Errors::ServiceError => e
          details[kind] = nil
          operation = e.context.operation_name.to_s.split("_").map(&:capitalize).join
          errors << ComputeInventory.error_entry(operation, e)
        end
      end
      record.merge(
        "details_collected_at" => Time.now.utc.iso8601,
        "details" => details,
        "errors" => record["errors"] + errors,
      )
    end

    private

    # 詳細を取る呼び出しは、1 回ごとに間隔を空ける
    def pace
      sleep @interval
      yield
    end

    # 2 ページ目以降の呼び出しにも間隔を空ける
    def paged
      pages = [pace { yield }]
      pages << pace { pages.last.next_page } while pages.last.next_page?
      pages
    end

    # タスク定義: 同じものは 1 回だけ引く
    def task_definition(record)
      arn = record["task_definition"]
      td = @cache[[:task_definition, arn]] ||= pace { @ecs.describe_task_definition(task_definition: arn).task_definition }
      {
        "family" => td.family,
        "revision" => td.revision,
        "cpu" => td.cpu,
        "memory" => td.memory,
        "os_family" => td.runtime_platform&.operating_system_family,
        "cpu_architecture" => td.runtime_platform&.cpu_architecture,
        "containers" => (td.container_definitions || []).map { |c| { "name" => c.name, "image" => c.image } },
      }
    end

    # サービスのタスクと、それが動いているホスト
    def tasks(record)
      cluster = record["cluster_name"]
      arns = paged { @ecs.list_tasks(cluster: cluster, service_name: record["service_name"]) }.flat_map(&:task_arns)
      arns.each_slice(100).flat_map { |chunk| pace { @ecs.describe_tasks(cluster: cluster, tasks: chunk) }.tasks }.map do |t|
        {
          "task_arn" => t.task_arn,
          "task_definition" => t.task_definition_arn,
          "last_status" => t.last_status,
          "launch_type" => t.launch_type,
          "container_instance_arn" => t.container_instance_arn,
          "availability_zone" => t.availability_zone,
          "started_at" => ComputeInventory.utc_iso(t.started_at),
        }
      end
    end

    # ECS サービスは自分のターゲットグループだけを見る。
    # EC2 インスタンスはどこに登録されているかわからないので、すべてのターゲットグループを見る（実行ごとに 1 回）
    def target_health(record)
      if record["record_type"] == "ecs_service"
        record["load_balancers"].filter_map { |lb| lb["target_group_arn"] }.uniq.flat_map { |tg| target_health_of(tg) }
      else
        all_target_groups.flat_map { |tg| target_health_of(tg) }.select { |h| h["target_id"] == record["instance_id"] }
      end
    end

    def all_target_groups
      @cache[:target_groups] ||= paged { @elb.describe_target_groups }.flat_map(&:target_groups).map(&:target_group_arn)
    end

    # ターゲットグループごとの結果は 1 回だけ引く
    def target_health_of(tg)
      @cache[[:target_health, tg]] ||= pace { @elb.describe_target_health(target_group_arn: tg) }
                                       .target_health_descriptions.map do |d|
        {
          "target_group_arn" => tg,
          "target_id" => d.target.id,
          "port" => d.target.port,
          "state" => d.target_health&.state,
          "reason" => d.target_health&.reason,
        }
      end
    end
  end

  # ------------------------------------------------------------ CLI

  USAGE = <<~USAGE
    usage:
      compute_inventory.rb snapshot [--ec2-filter Name=...,Values=...]... [--cluster NAME]...
      compute_inventory.rb detail --with KIND[,KIND...] [--interval SEC] [--max N] < records.jsonl

      KIND: #{DETAIL_KINDS.join(', ')}
  USAGE

  def main(argv)
    case argv.shift
    when "snapshot" then run_snapshot(argv)
    when "detail" then run_detail(argv)
    else abort USAGE
    end
  end

  def run_snapshot(argv)
    ec2_filters = []
    clusters = []
    OptionParser.new(USAGE) do |o|
      o.on("--ec2-filter FILTER") { |v| ec2_filters << parse_ec2_filter(v) }
      o.on("--cluster NAME") { |v| clusters << v }
    end.parse!(argv)
    Snapshot.new(ec2_filters: ec2_filters, clusters: clusters).run($stdout)
  end

  # AWS CLI と同じ書き方（Name=tag:env,Values=prod,stg）を受け付ける
  def parse_ec2_filter(text)
    m = text.match(/\AName=([^,]+),Values=(.+)\z/) or abort "--ec2-filter の形が違います: #{text}"
    { name: m[1], values: m[2].split(",") }
  end

  def run_detail(argv)
    kinds = []
    interval = 0.2
    max = 100
    OptionParser.new(USAGE) do |o|
      o.on("--with KINDS") { |v| kinds = v.split(",") }
      o.on("--interval SEC", Float) { |v| interval = v }
      o.on("--max N", Integer) { |v| max = v }
    end.parse!(argv)
    abort USAGE if kinds.empty?
    (kinds - DETAIL_KINDS).each { |k| abort "不明な詳細の種類: #{k}" }

    # 件数が多すぎるときは、絞り込み忘れとみなして止める
    records = $stdin.each_line.reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
    if records.size > max
      abort "入力が #{records.size} 件あり、上限（--max #{max}）を超えています。jq で絞り込むか、--max を上げてください"
    end

    detail = Detail.new(kinds: kinds, interval: interval)
    records.each { |record| $stdout.puts JSON.generate(detail.enrich(record)) }
  end
end

ComputeInventory.main(ARGV) if $PROGRAM_NAME == __FILE__
