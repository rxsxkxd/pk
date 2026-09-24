#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 5 内部処理: switchover.sh から呼ばれる。検証済みの RDS Blue/Green Deployment を切り替える。
# このスクリプトは本番トラフィックに影響する変更操作を実行するため、--approve を必須とする。

require 'fileutils'
require 'optparse'
require 'tmpdir'

require_relative 'lib/aws_cli'
require_relative 'lib/deployment_config'

USAGE = <<~USAGE
  Usage: switchover_blue_green_deployment.rb --config FILE --blue-green-deployment-id ID --approve [options]
    --config FILE                  環境別設定ファイル（必須）
    --blue-green-deployment-id ID  切替対象の Blue/Green Deployment 識別子（必須）
    --approve                      検証完了後の切替を明示承認する必須フラグ
    --switchover-timeout SEC       RDS に渡す切替タイムアウト秒数（default: 300）
    --region REGION                AWS Region（設定ファイルの aws_region を上書き）
    --profile PROFILE              AWS CLI profile（省略時は AWS CLI の既定認証情報）
    --output-dir DIR               応答 JSON の保存先（default: temporary directory）
USAGE

options = { approve: false, switchover_timeout: '300', region: '', profile: '', output_dir: '' }
parser = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on('--config FILE') { |v| options[:config] = v }
  opts.on('--blue-green-deployment-id ID') { |v| options[:deployment_identifier] = v }
  opts.on('--approve') { options[:approve] = true }
  opts.on('--switchover-timeout SEC') { |v| options[:switchover_timeout] = v }
  opts.on('--region REGION') { |v| options[:region] = v }
  opts.on('--profile PROFILE') { |v| options[:profile] = v }
  opts.on('--output-dir DIR') { |v| options[:output_dir] = v }
  opts.on('-h', '--help') { puts opts; exit 0 }
end
begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn USAGE
  exit 2
end

if options[:config].to_s.empty?
  warn '--config is required.'
  exit 2
end
if options[:deployment_identifier].to_s.empty?
  warn '--blue-green-deployment-id is required.'
  exit 2
end
unless options[:approve]
  warn '--approve is required because switchover changes production routing.'
  exit 2
end
unless options[:switchover_timeout].match?(/\A[0-9]+\z/)
  warn '--switchover-timeout must be an integer.'
  exit 2
end

output_dir = options[:output_dir]
output_dir = Dir.mktmpdir('rds-bg-switchover') if output_dir.to_s.empty?
FileUtils.mkdir_p(output_dir)

# config から環境に紐づく AWS CLI のリージョン・プロファイルを取得する。AWS API は呼び出さない。
begin
  config = DeploymentConfig.load(options[:config])
  region = options[:region].to_s.empty? ? config.required('aws_region') : options[:region]
  profile = options[:profile].to_s.empty? ? config.optional('aws_profile') : options[:profile]
rescue DeploymentConfig::Error => e
  warn e.message
  exit 1
end

aws = AwsCli.new(region: region, profile: profile)
deployment_identifier = options[:deployment_identifier]

begin
  # [切替前・読み取り] 対象 Deployment の現在状態を取得する。
  # Green 構築と検証が完了した AVAILABLE 状態だけを切替対象にする。
  before = aws.run_json('rds', 'describe-blue-green-deployments',
                        '--blue-green-deployment-identifier', deployment_identifier,
                        save_to: File.join(output_dir, 'before-switchover.json'))
  status = before.dig('BlueGreenDeployments', 0, 'Status')
  unless status == 'AVAILABLE'
    warn "Switchover requires AVAILABLE status; current status: #{status}"
    exit 1
  end

  # [変更] RDS の Blue/Green Deployment を切り替える。切替後は Green が本番 DB となる。
  aws.run_json('rds', 'switchover-blue-green-deployment',
               '--blue-green-deployment-identifier', deployment_identifier,
               '--switchover-timeout', options[:switchover_timeout],
               save_to: File.join(output_dir, 'switchover-blue-green-deployment.json'))
rescue AwsCli::Error => e
  warn e.message
  exit 1
end

puts "Switchover started: #{deployment_identifier}"
puts "Artifacts: #{output_dir}"
puts "Monitor with: #{aws.command_prefix} rds describe-blue-green-deployments " \
     "--blue-green-deployment-identifier #{deployment_identifier} --output json"
