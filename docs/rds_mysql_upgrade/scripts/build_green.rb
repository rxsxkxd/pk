#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 3 内部処理: build_green.sh から呼ばれる。**使える Blue/Green Deployment が
# 存在する状態にする**（冪等）。切替は実施しない。
#
# build_green.sh がフェーズ判定（冪等性の第 1 層。移行元が移行前の姿であること）を
# 済ませてから呼ぶ。ここは第 2 層で、移行元に対応する Deployment の Status で分岐する。
#
#   AVAILABLE        既に目的の状態。何もせず成功
#   PROVISIONING     作成途中。二重作成せず AVAILABLE を待つ
#   それ以外         INVALID_CONFIGURATION / SWITCHOVER_FAILED / DELETING など。
#                    「存在するから成功」と扱うと、失敗した Deployment が残る限り
#                    永久に成功を返し続ける（サイレント失敗）。ここで止める
#   存在しない       保護スナップショットを確保してから作成し、AVAILABLE を待つ
#
# Deployment ID は設定ファイルに持たず、移行元の ARN で毎回 AWS から引き当てる（中核ルール）。
# 変更操作は `# [変更]` の 2 か所（保護スナップショットの作成、Blue/Green の作成）だけである。
#
# 終了コード: 0 AVAILABLE な Deployment がある / 1 到達しておらず自動では到達できない / 2 引数の誤り
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
    --region REGION             AWS Region（設定ファイルの aws_region を上書き）
    --profile PROFILE           AWS CLI profile（省略時は AWS CLI の既定認証情報）
    --output-dir DIR            応答 JSON の保存先（default: temporary directory）
    --poll-interval-seconds SEC 状態確認の間隔（default: 30。テストで短くするため）
USAGE

# AVAILABLE 待機の上限秒数。Green の作成は大きな DB で長くかかる。
WAIT_TIMEOUT_SECONDS = 3600

options = { region: '', profile: '', output_dir: '', poll_interval_seconds: '30' }
parser = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on('--service NAME') { |v| options[:service] = v }
  opts.on('--config FILE') { |v| options[:config] = v }
  opts.on('--region REGION') { |v| options[:region] = v }
  opts.on('--profile PROFILE') { |v| options[:profile] = v }
  opts.on('--output-dir DIR') { |v| options[:output_dir] = v }
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

%i[service config].each do |key|
  next unless options[key].to_s.empty?

  warn "--#{key} is required."
  exit 2
end
unless options[:poll_interval_seconds].match?(/\A[0-9]+\z/)
  warn '--poll-interval-seconds must be an integer.'
  exit 2
end

output_dir = options[:output_dir]
output_dir = Dir.mktmpdir('rds-bg-create') if output_dir.to_s.empty?
FileUtils.mkdir_p(output_dir)

# config のサービスに対応する作成設定を読み取る。AWS API は呼び出さない。
begin
  config = DeploymentConfig.load(options[:config])
  service = config.service(options[:service])
  source_db_instance_identifier = service.required('source_db_instance_identifier')
  snapshot_identifier = service.required('protection_snapshot_identifier')
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
save = ->(name) { File.join(output_dir, name) }

# Deployment が AVAILABLE になるまで待つ。AWS CLI に Blue/Green 用の waiter は無い
# （RDS の waiter は DBInstance / DBSnapshot 系のみ）ため、明示的にポーリングする。
# PROVISIONING 以外の状態になったら、待っても AVAILABLE にはならないので打ち切る。
wait_for_available = lambda do |deployment_identifier|
  deadline = Time.now + WAIT_TIMEOUT_SECONDS
  loop do
    # [待機中・読み取り] Green の構築状態を取得する。
    described = aws.run_json('rds', 'describe-blue-green-deployments',
                             '--blue-green-deployment-identifier', deployment_identifier,
                             save_to: save.('describe-blue-green-deployment.json'))
    status = described.dig('BlueGreenDeployments', 0, 'Status')
    puts "Blue/Green status: #{status}"
    return true if status == 'AVAILABLE'

    unless status == 'PROVISIONING'
      warn "Blue/Green Deployment did not become available; status: #{status}"
      return false
    end
    if Time.now >= deadline
      warn 'Timed out waiting for AVAILABLE.'
      return false
    end
    sleep options[:poll_interval_seconds].to_i
  end
end

finish = lambda do |deployment_identifier|
  puts 'Green is AVAILABLE. Perform verification before switchover.'
  puts "Deployment identifier: #{deployment_identifier}"
  puts "Artifacts: #{output_dir}"
  exit 0
end

begin
  # [読み取り] 移行元の ARN・エンジン。Deployment の引き当てと作成の Source に使う。
  source = aws.run_json('rds', 'describe-db-instances',
                        '--db-instance-identifier', source_db_instance_identifier,
                        save_to: save.('source-db-instance.json'))
  instance = source.dig('DBInstances', 0) || {}
  source_db_instance_arn = instance['DBInstanceArn'].to_s
  if source_db_instance_arn.empty?
    warn "移行元 #{source_db_instance_identifier} の ARN を取得できない"
    exit 1
  end

  # --- 既存の Deployment の状態で分岐する ------------------------------------
  deployments = aws.run_json('rds', 'describe-blue-green-deployments',
                             '--filters', "Name=source,Values=#{source_db_instance_arn}",
                             save_to: save.('deployments.json'))
  existing = deployments.dig('BlueGreenDeployments', 0)
  if existing
    existing_identifier = existing['BlueGreenDeploymentIdentifier']
    case existing['Status']
    when 'AVAILABLE'
      puts "Blue/Green Deployment already available: #{existing_identifier}"
      finish.(existing_identifier)
    when 'PROVISIONING'
      puts "Blue/Green Deployment is provisioning: #{existing_identifier}"
      exit 1 unless wait_for_available.(existing_identifier)
      finish.(existing_identifier)
    else
      warn "Blue/Green Deployment exists but is not usable: #{existing_identifier} (status: #{existing['Status']})"
      warn '内容を確認し、不要であれば削除してから再実行する。'
      exit 1
    end
  end

  # --- ここから新規作成 ------------------------------------------------------
  # [作成前・読み取り] 移行元が 8.0 の MySQL であることを確かめる。
  unless instance['Engine'] == 'mysql'
    warn "Source DB engine must be mysql: #{instance['Engine']}"
    exit 1
  end
  unless instance['EngineVersion'].to_s.start_with?('8.0.')
    warn "Source DB engine must be MySQL 8.0: #{instance['EngineVersion']}"
    exit 1
  end

  # [作成前・読み取り] CloudFormation で事前作成した DB パラメータグループが mysql8.4 ファミリーであること。
  group = aws.run_json('rds', 'describe-db-parameter-groups',
                       '--db-parameter-group-name', target_db_parameter_group_name,
                       save_to: save.('target-db-parameter-group.json'))
  family = group.dig('DBParameterGroups', 0, 'DBParameterGroupFamily')
  unless family == 'mysql8.4'
    warn "Target DB parameter group family must be mysql8.4: #{family}"
    exit 1
  end

  # Deployment 名はサービス・環境・時刻から決める（識別は移行元の ARN で行うので、名前には依らない）。
  deployment_name = "#{options[:service]}-#{environment}-mysql84-bg-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
  unless deployment_name.match?(/\A[A-Za-z][A-Za-z0-9-]{0,59}\z/)
    warn "サービス名と環境名から作った Deployment 名が RDS の命名規則に合わない: #{deployment_name}"
    exit 1
  end

  # --- 保護スナップショット（切り戻し可能な状態を作成前に確保する）----------
  # 存在の有無だけでなく Status を見る。failed のまま待つと無駄にブロックされる。
  # 「無い」と扱うのは DBSnapshotNotFound のときだけで、権限不足などは失敗として止める。
  snapshot_status =
    begin
      aws.run('rds', 'describe-db-snapshots', '--db-snapshot-identifier', snapshot_identifier,
              '--query', 'DBSnapshots[0].Status', '--output', 'text').strip
    rescue AwsCli::Error => e
      raise unless e.message.include?('DBSnapshotNotFound')

      ''
    end
  case snapshot_status
  when '', 'None'
    # [変更] 保護スナップショットを作成する。
    aws.run_json('rds', 'create-db-snapshot',
                 '--db-instance-identifier', source_db_instance_identifier,
                 '--db-snapshot-identifier', snapshot_identifier,
                 save_to: save.('create-snapshot.json'))
    puts "Protection snapshot requested: #{snapshot_identifier}"
  when 'available', 'creating'
    puts "Protection snapshot is #{snapshot_status}: #{snapshot_identifier}"
  else
    warn "Protection snapshot is in an unusable state: #{snapshot_identifier} (status: #{snapshot_status})"
    warn '削除して作り直すか、別の識別子を config に指定する。'
    exit 1
  end
  # [読み取り待機] available になるまで待ち、作成前の復旧可能性を確定する。
  aws.run('rds', 'wait', 'db-snapshot-available', '--db-snapshot-identifier', snapshot_identifier)
  aws.run_json('rds', 'describe-db-snapshots', '--db-snapshot-identifier', snapshot_identifier,
               save_to: save.('snapshot.json'))

  # [変更] 8.0 の Source から MySQL 8.4 Green を作成する。
  # target_db_parameter_group_name は CloudFormation が作成済みの実名を RDS API に直接渡す。
  created = aws.run_json('rds', 'create-blue-green-deployment',
                         '--blue-green-deployment-name', deployment_name,
                         '--source', source_db_instance_arn,
                         '--target-engine-version', target_engine_version,
                         '--target-db-instance-class', target_db_instance_class,
                         '--target-db-parameter-group-name', target_db_parameter_group_name,
                         save_to: save.('create-blue-green-deployment.json'))
  # create-blue-green-deployment は呼び直せない（呼び直すと二重作成になる）。
  # 応答の形が変わって識別子を取れなかった場合に、空文字のまま先へ進ませない。
  deployment_identifier = created.dig('BlueGreenDeployment', 'BlueGreenDeploymentIdentifier')
  if deployment_identifier.to_s.empty?
    warn 'create-blue-green-deployment.json から BlueGreenDeploymentIdentifier を取得できなかった。'
    exit 1
  end
  puts "Created Blue/Green Deployment: #{deployment_identifier}"
  exit 1 unless wait_for_available.(deployment_identifier)
  finish.(deployment_identifier)
rescue AwsCli::Error => e
  warn e.message
  exit 1
end
