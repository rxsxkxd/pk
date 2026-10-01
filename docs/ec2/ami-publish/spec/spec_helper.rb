# frozen_string_literal: true

require "stringio"
require_relative "../lib/ami_publish"

module SpecHelpers
  SETTINGS = {
    "aws_region" => "ap-northeast-1",
    "application_name" => "myapp",
    "release_instance_id" => "i-0123456789abcdef0",
    "timeouts" => { "image_available_seconds" => 60, "instance_online_seconds" => 60,
                    "health_check_seconds" => 60, "stack_update_seconds" => 60,
                    "poll_interval_seconds" => 0,
                    "progress_log_interval_seconds" => 0 }
  }.freeze

  def configuration(overrides = {})
    AmiPublish::Configuration.new("staging", SETTINGS.merge(overrides))
  end

  # AWS に接続しないスタブのクライアント。各テストで stub_responses を設定し、api_requests で呼び出しを確かめる。
  def stub_clients
    AmiPublish::AwsClientFactory.new(region: "ap-northeast-1", client_options: { stub_responses: true })
  end

  def log_output
    @log_output ||= StringIO.new
  end

  def logger
    AmiPublish::StructuredLogger.new(output: log_output)
  end

  def log_events
    log_output.string.lines.map { |line| JSON.parse(line)["event"] }
  end

  # 進捗ログ（event: waiting）だけを取り出す
  def waiting_logs
    log_output.string.lines.map { |line| JSON.parse(line) }.select { |record| record["event"] == "waiting" }
  end

  # 1 回目の確認で待機時間を使い切る Poller（タイムアウトの試験用）。
  def expiring_poller
    now = 0
    AmiPublish::Poller.new(interval_seconds: 0, clock: -> { now += 1000 }, sleeper: ->(_) {})
  end

  # パイプラインのスタックの出力（テストでは固定値を返す）
  PIPELINE_OUTPUTS = {
    "LaunchTemplateStackName" => "myapp-staging-launch-template",
    "HealthCheckDocumentName" => "myapp-staging-health-check",
    "LogGroupName" => "/myapp/staging/ami-publish",
    "ReleaseInstanceRoleArn" => "arn:aws:iam::123456789012:role/release-instance",
    "ReleaseInstanceProfileArn" => "arn:aws:iam::123456789012:instance-profile/release-instance"
  }.freeze
  StaticOutputs = Struct.new(:outputs) do
    def fetch(key) = outputs.fetch(key)
  end

  def step_dependencies(clients, **overrides)
    { configuration: configuration, clients: clients, logger: logger,
      poller: AmiPublish::Poller.new(interval_seconds: 0, sleeper: ->(_) {}),
      pipeline_outputs: StaticOutputs.new(PIPELINE_OUTPUTS) }.merge(overrides)
  end

  # パイプラインのスタックの出力を返す describe_stacks の応答
  def pipeline_stack_response(outputs = PIPELINE_OUTPUTS)
    { stacks: [{ stack_name: "myapp-staging-ami-publish-pipeline", creation_time: Time.now,
                 stack_status: "UPDATE_COMPLETE",
                 outputs: outputs.map { |key, value| { output_key: key, output_value: value } } }] }
  end

  # インスタンスプロファイルの紐付け（describe_iam_instance_profile_associations の 1 件分）
  def profile_association(arn: PIPELINE_OUTPUTS["ReleaseInstanceProfileArn"], state: "associated", id: "iip-assoc-1")
    { association_id: id, instance_id: "i-0123456789abcdef0", state: state,
      iam_instance_profile: { arn: arn, id: "id" } }
  end

  # 紐付け・解除の操作に応じて、紐付けの一覧が変わるスタブ
  def stub_profile_association_lifecycle(client, associated: false)
    client.stub_responses(:associate_iam_instance_profile, lambda { |_|
      associated = true
      { iam_instance_profile_association: profile_association(state: "associating") }
    })
    client.stub_responses(:disassociate_iam_instance_profile, lambda { |_|
      associated = false
      { iam_instance_profile_association: profile_association(state: "disassociating") }
    })
    client.stub_responses(:describe_iam_instance_profile_associations, lambda { |_|
      { iam_instance_profile_associations: associated ? [profile_association] : [] }
    })
  end

  def requests(client, operation)
    client.api_requests.select { |request| request[:operation_name] == operation }
  end

  def context(**values)
    AmiPublish::RunContext.new(version: "v1.2.3", verified: "manual", pipeline_execution_id: "exec-1",
                               dry_run: false, **values)
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.disable_monkey_patching!
  config.order = :random
end
