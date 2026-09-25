#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 5 内部処理: switchover.sh から呼ばれる。移行元に対応する Blue/Green Deployment を
# 切り替え、**切替完了まで待つ**（冪等）。本番トラフィックに影響するため --approve を必須とする。
#
# switchover.sh がフェーズ判定（冪等性の第 1 層。切替済みなら何もしない）を済ませてから呼ぶ。
# ここは第 2 層（安全弁）で、Deployment の Status で分岐する。
#
#   AVAILABLE               切り替え、SWITCHOVER_COMPLETED まで待つ
#   SWITCHOVER_IN_PROGRESS  既に切替が走っている。API を二重に呼ばず完了だけを待つ
#                           （リネームは完了時に行われるため、進行中は第 1 層だけでは
#                           「まだ切替前」と誤認する）
#   それ以外                止める
#   存在しない              止める（Step 3 が未実行か、誤って削除されている）
#
# Deployment ID は設定ファイルに持たず、移行元の ARN で毎回 AWS から引き当てる（中核ルール）。
# 変更操作は `# [変更]` の 1 か所（switchover-blue-green-deployment）だけである。
#
# 終了コード: 0 切替完了に到達 / 1 到達しておらず自動では到達できない / 2 引数の誤り
require 'fileutils'
require 'optparse'
require 'tmpdir'

require_relative 'lib/aws_cli'
require_relative 'lib/deployment_config'

USAGE = <<~USAGE
  Usage: switchover_blue_green_deployment.rb --config FILE --service NAME --approve [options]
    --config FILE                環境別設定ファイル（必須）
    --service NAME               config の services 配下に定義したサービス名（必須）
    --approve                    本番トラフィックに影響する操作を明示承認する必須フラグ
    --region REGION              AWS Region（空なら設定ファイルの aws_region）
    --profile PROFILE            AWS CLI profile（空なら設定ファイルの aws_profile）
    --output-dir DIR             応答 JSON の保存先（default: temporary directory）
    --wait-timeout-seconds SEC   切替完了待機の上限秒数（default: 1800）
    --poll-interval-seconds SEC  状態確認の間隔（default: 15。テストで短くするため）
USAGE

options = { approve: false, region: '', profile: '', output_dir: '',
            wait_timeout_seconds: '1800', poll_interval_seconds: '15' }
parser = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on('--config FILE') { |v| options[:config] = v }
  opts.on('--service NAME') { |v| options[:service] = v }
  opts.on('--approve') { options[:approve] = true }
  opts.on('--region REGION') { |v| options[:region] = v }
  opts.on('--profile PROFILE') { |v| options[:profile] = v }
  opts.on('--output-dir DIR') { |v| options[:output_dir] = v }
  opts.on('--wait-timeout-seconds SEC') { |v| options[:wait_timeout_seconds] = v }
  opts.on('--poll-interval-seconds SEC') { |v| options[:poll_interval_seconds] = v }
  opts.on('-h', '--help') { puts opts; exit 0 }
end
begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn USAGE
  exit 2
end
%i[config service].each do |key|
  next unless options[key].to_s.empty?

  warn "--#{key} is required."
  exit 2
end
unless options[:approve]
  warn '--approve is required because switchover changes production routing.'
  exit 2
end
%i[wait_timeout_seconds poll_interval_seconds].each do |key|
  next if options[key].match?(/\A[0-9]+\z/)

  warn "--#{key.to_s.tr('_', '-')} must be an integer."
  exit 2
end

output_dir = options[:output_dir]
output_dir = Dir.mktmpdir('rds-bg-switchover') if output_dir.to_s.empty?
FileUtils.mkdir_p(output_dir)
save = ->(name) { File.join(output_dir, name) }

# 設定を読む。AWS API は呼び出さない。
begin
  config = DeploymentConfig.load(options[:config])
  service = config.service(options[:service])
  source_id = service.required('source_db_instance_identifier')
  # RDS に渡す切替タイムアウト（秒）。切替そのものの上限で、待機の上限とは別物である。
  switchover_timeout = service.optional('actions.switchover_timeout', '300')
  region = options[:region].empty? ? config.required('aws_region') : options[:region]
  profile = options[:profile].empty? ? config.optional('aws_profile') : options[:profile]
rescue DeploymentConfig::Error => e
  warn e.message
  exit 1
end
unless switchover_timeout.match?(/\A[0-9]+\z/)
  warn "actions.switchover_timeout must be an integer: #{switchover_timeout}"
  exit 1
end

aws = AwsCli.new(region: region, profile: profile)

# SWITCHOVER_COMPLETED になるまで待つ。AWS CLI に Blue/Green 用の waiter は無い。
# SWITCHOVER_IN_PROGRESS 以外になったら、待っても完了しないので打ち切る。
wait_for_switchover = lambda do |deployment_identifier|
  deadline = Time.now + options[:wait_timeout_seconds].to_i
  loop do
    described = aws.run_json('rds', 'describe-blue-green-deployments',
                             '--blue-green-deployment-identifier', deployment_identifier,
                             save_to: save.('after-switchover.json'))
    status = described.dig('BlueGreenDeployments', 0, 'Status')
    case status
    when 'SWITCHOVER_COMPLETED'
      puts "Switchover completed: #{deployment_identifier}"
      return true
    when 'SWITCHOVER_IN_PROGRESS'
      puts "  status: #{status}"
    else
      warn "Switchover did not complete; status: #{status}"
      return false
    end
    if Time.now >= deadline
      warn 'Timed out waiting for SWITCHOVER_COMPLETED.'
      return false
    end
    sleep options[:poll_interval_seconds].to_i
  end
end

begin
  # [読み取り] 移行元の ARN。Deployment を source で引き当てるためである。
  source = aws.run_json('rds', 'describe-db-instances', '--db-instance-identifier', source_id,
                        save_to: save.('source.json'))
  source_arn = source.dig('DBInstances', 0, 'DBInstanceArn').to_s
  if source_arn.empty?
    warn "移行元 #{source_id} の ARN を取得できない"
    exit 1
  end

  # [読み取り] Source に紐づく Deployment。設定値ではなく AWS の実状態から対象を解決する。
  deployments = aws.run_json('rds', 'describe-blue-green-deployments',
                             '--filters', "Name=source,Values=#{source_arn}",
                             save_to: save.('deployment.json'))
  deployment = deployments.dig('BlueGreenDeployments', 0)
  if deployment.nil?
    warn "Blue/Green Deployment not found for #{source_id} (phase: pre_switchover)."
    warn 'Step 3（build_green.sh）が完了しているか確認する。'
    exit 1
  end
  deployment_identifier = deployment['BlueGreenDeploymentIdentifier']

  case deployment['Status']
  when 'AVAILABLE'
    # [変更] RDS の Blue/Green Deployment を切り替える。切替後は Green が本番 DB となる。
    aws.run_json('rds', 'switchover-blue-green-deployment',
                 '--blue-green-deployment-identifier', deployment_identifier,
                 '--switchover-timeout', switchover_timeout,
                 save_to: save.('switchover-blue-green-deployment.json'))
    puts "Switchover started: #{deployment_identifier}"
  when 'SWITCHOVER_IN_PROGRESS'
    puts "Switchover already in progress: #{deployment_identifier}"
  else
    warn "Switchover requires AVAILABLE status; current status: #{deployment['Status']}"
    exit 1
  end
  exit 1 unless wait_for_switchover.(deployment_identifier)
  puts "Artifacts: #{output_dir}"
rescue AwsCli::Error => e
  warn e.message
  exit 1
end
