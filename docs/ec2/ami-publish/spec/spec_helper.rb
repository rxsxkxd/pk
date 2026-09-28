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

  def step_dependencies(clients, **overrides)
    { configuration: configuration, clients: clients, logger: logger,
      poller: AmiPublish::Poller.new(interval_seconds: 0, sleeper: ->(_) {}) }.merge(overrides)
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
