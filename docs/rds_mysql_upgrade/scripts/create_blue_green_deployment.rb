#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 3 内部処理: build_green.sh から呼ばれる。CloudFormation で事前作成済みの
# MySQL 8.4 DB パラメータグループを直接指定し、RDS for MySQL 8.0 の Blue から 8.4 の Green を作成する。
# Green が AVAILABLE になるまで待機して終了する。切替は実施しない。
#
# 同じ内容のシェル版 create_blue_green_deployment.sh を残してある。
# **どちらを変えても、もう一方へ同じ変更を入れる。**
require 'fileutils'
require 'optparse'
require 'time'
require 'tmpdir'

require_relative 'lib/aws_cli'
require_relative 'lib/deployment_config'

USAGE = <<~USAGE
  Usage: create_blue_green_deployment.rb --config FILE --service NAME [options]
    --config FILE               環境別設定ファイル（必須）
    --service NAME              config の services 配下に定義したサービス名（必須）
    --deployment-name NAME      Blue/Green Deployment 名（省略時はサービス・環境・時刻から生成）
    --region REGION             AWS Region（設定ファイルの aws_region を上書き）
    --profile PROFILE           AWS CLI profile（省略時は AWS CLI の既定認証情報）
    --output-dir DIR            応答 JSON の保存先（default: temporary directory）
    --wait-timeout-seconds SEC  AVAILABLE 待機の上限秒数（default: 3600）
USAGE

# 待機の間隔。シェル版の sleep 30 と揃える。
POLL_INTERVAL_SECONDS = 30
# これらの状態になったら待機を打ち切る。
TERMINAL_FAILURE_STATUSES = %w[INVALID_CONFIGURATION FAILED DELETED].freeze

options = { region: '', profile: '', output_dir: '', wait_timeout_seconds: '3600', deployment_name: '' }
parser = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on('--service NAME') { |v| options[:service] = v }
  opts.on('--deployment-name NAME') { |v| options[:deployment_name] = v }
  opts.on('--config FILE') { |v| options[:config] = v }
  opts.on('--region REGION') { |v| options[:region] = v }
  opts.on('--profile PROFILE') { |v| options[:profile] = v }
  opts.on('--output-dir DIR') { |v| options[:output_dir] = v }
  opts.on('--wait-timeout-seconds SEC') { |v| options[:wait_timeout_seconds] = v }
  opts.on('-h', '--help') { puts opts; exit 0 }
end
begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn USAGE
  exit 2
end

if options[:service].to_s.empty?
  warn '--service is required.'
  exit 2
end
if options[:config].to_s.empty?
  warn '--config is required.'
  exit 2
end
unless options[:wait_timeout_seconds].match?(/\A[0-9]+\z/)
  warn '--wait-timeout-seconds must be an integer.'
  exit 2
end
# JSON の読み取りは Ruby の標準ライブラリで行う（シェル版と違い jq を必要としない）。

output_dir = options[:output_dir]
output_dir = Dir.mktmpdir('rds-bg-create') if output_dir.to_s.empty?
FileUtils.mkdir_p(output_dir)

# config のサービスに対応する作成設定を読み取る。AWS API は呼び出さない。
begin
  config = DeploymentConfig.load(options[:config])
  service = config.service(options[:service])
  source_db_instance_identifier = service.required('source_db_instance_identifier')
  target_engine_version = service.required('target_engine_version')
  target_db_instance_class = service.required('target_db_instance_class')
  target_db_parameter_group_name = service.required('target_db_parameter_group_name')
  environment = config.required('environment')
  region = options[:region].to_s.empty? ? config.required('aws_region') : options[:region]
  profile = options[:profile].to_s.empty? ? config.optional('aws_profile') : options[:profile]
rescue DeploymentConfig::Error => e
  warn e.message
  exit 1
end

aws = AwsCli.new(region: region, profile: profile)

begin
  # [作成前・読み取り] 移行元 Blue DB の ARN・エンジン・現在の状態を取得する。
  # CreateBlueGreenDeployment の Source に渡す ARN を確定し、8.0 MySQL であることを確認するための操作。
  source = aws.run_json('rds', 'describe-db-instances',
                        '--db-instance-identifier', source_db_instance_identifier,
                        save_to: File.join(output_dir, 'source-db-instance.json'))
  instance = source.dig('DBInstances', 0) || {}
  unless instance['Engine'] == 'mysql'
    warn "Source DB engine must be mysql: #{instance['Engine']}"
    exit 1
  end
  unless instance['EngineVersion'].to_s.start_with?('8.0.')
    warn "Source DB engine must be MySQL 8.0: #{instance['EngineVersion']}"
    exit 1
  end
  source_db_instance_arn = instance['DBInstanceArn']

  # [作成前・読み取り] CloudFormation で事前作成した DB パラメータグループの family を取得する。
  # Green の MySQL 8.4 に適用可能な mysql8.4 ファミリーであることを確認するための操作。
  group = aws.run_json('rds', 'describe-db-parameter-groups',
                       '--db-parameter-group-name', target_db_parameter_group_name,
                       save_to: File.join(output_dir, 'target-db-parameter-group.json'))
  family = group.dig('DBParameterGroups', 0, 'DBParameterGroupFamily')
  unless family == 'mysql8.4'
    warn "Target DB parameter group family must be mysql8.4: #{family}"
    exit 1
  end

  deployment_name = options[:deployment_name]
  if deployment_name.to_s.empty?
    deployment_name = "#{options[:service]}-#{environment}-mysql84-bg-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
  end
  unless deployment_name.match?(/\A[A-Za-z][A-Za-z0-9-]{0,59}\z/)
    warn "Invalid --deployment-name: #{deployment_name}"
    exit 2
  end

  # [変更] 8.0 の Source から MySQL 8.4 Green を作成する。
  # target_db_parameter_group_name は CloudFormation が作成済みの実名を RDS API に直接渡す。
  created = aws.run_json('rds', 'create-blue-green-deployment',
                         '--blue-green-deployment-name', deployment_name,
                         '--source', source_db_instance_arn,
                         '--target-engine-version', target_engine_version,
                         '--target-db-instance-class', target_db_instance_class,
                         '--target-db-parameter-group-name', target_db_parameter_group_name,
                         save_to: File.join(output_dir, 'create-blue-green-deployment.json'))
  # create-blue-green-deployment は変更操作であり呼び直せない（呼び直すと二重作成になる）。
  # 応答の形が変わって識別子を取れなかった場合に、空文字のまま先へ進ませない。
  deployment_identifier = created.dig('BlueGreenDeployment', 'BlueGreenDeploymentIdentifier')
  if deployment_identifier.to_s.empty?
    warn 'create-blue-green-deployment.json から BlueGreenDeploymentIdentifier を取得できなかった。'
    exit 1
  end

  puts "Created Blue/Green Deployment: #{deployment_identifier}"
  puts 'Waiting for status AVAILABLE before verification...'
  deadline = Time.now + options[:wait_timeout_seconds].to_i
  loop do
    # [待機中・読み取り] Green の構築状態と、作成された Green DB の ARN を取得する。
    # AVAILABLE になった時点で終了し、アプリケーション・接続・性能検証へ進む。
    described = aws.run_json('rds', 'describe-blue-green-deployments',
                             '--blue-green-deployment-identifier', deployment_identifier,
                             save_to: File.join(output_dir, 'describe-blue-green-deployment.json'))
    status = described.dig('BlueGreenDeployments', 0, 'Status')
    puts "Blue/Green status: #{status}"
    break if status == 'AVAILABLE'
    if TERMINAL_FAILURE_STATUSES.include?(status)
      warn "Blue/Green creation failed: #{status}"
      exit 1
    end
    if Time.now >= deadline
      warn 'Timed out waiting for AVAILABLE.'
      exit 1
    end
    sleep POLL_INTERVAL_SECONDS
  end

  puts 'Green is AVAILABLE. Perform verification before switchover.'
  puts "Deployment identifier: #{deployment_identifier}"
  puts "Artifacts: #{output_dir}"
  puts 'Switchover: scripts/switchover_blue_green_deployment.rb ' \
       "--blue-green-deployment-id #{deployment_identifier} --approve"
rescue AwsCli::Error => e
  warn e.message
  exit 1
end
