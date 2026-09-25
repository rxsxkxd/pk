#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 構築前チェック: BuildGreen の直前に、移行先 DB パラメータグループの存在とファミリーを確認する
# （Step 1 の成立条件チェックとも、Step 4 の切替前検証とも別物である）。
# buildspec（ci/codebuild/precheck-target-parameter-group.yml）から ruby で直接呼ぶ。
#
# AWS API は describe-db-parameter-groups（読み取り）だけを使用する。
# 判定結果は不適合でも成果物（target-parameter-group-check.md）に残す。
#
# 終了コード: 0 適合 / 1 不適合、または取得の失敗 / 2 引数の誤り
require 'fileutils'
require 'optparse'
require 'tmpdir'

require_relative 'lib/aws_cli'
require_relative 'lib/deployment_config'

USAGE = 'Usage: check_target_parameter_group.rb --config FILE --service NAME [--region REGION] [--profile PROFILE] [--output-dir DIR]'

options = { region: '', profile: '', output_dir: '' }
parser = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on('--config FILE') { |v| options[:config] = v }
  opts.on('--service NAME') { |v| options[:service] = v }
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
if options[:config].to_s.empty? || options[:service].to_s.empty?
  warn USAGE
  exit 2
end
output_dir = options[:output_dir].empty? ? Dir.mktmpdir('rds-target-pg-check') : options[:output_dir]
FileUtils.mkdir_p(output_dir)

# 確認対象のパラメータグループ名と目標エンジンバージョンを設定から読む。AWS API は呼ばない。
begin
  config = DeploymentConfig.load(options[:config])
  service = config.service(options[:service])
  target_name = service.required('target_db_parameter_group_name')
  target_version = service.required('target_engine_version')
  region = options[:region].empty? ? config.required('aws_region') : options[:region]
  profile = options[:profile].empty? ? config.optional('aws_profile') : options[:profile]
rescue DeploymentConfig::Error => e
  warn e.message
  exit 1
end

# [読み取り] 指定したパラメータグループが存在するか、どのファミリーに属するかを取得する。
begin
  groups = AwsCli.new(region: region, profile: profile)
                 .run_json('rds', 'describe-db-parameter-groups', '--db-parameter-group-name', target_name,
                           save_to: File.join(output_dir, 'target-db-parameter-group.json'))
                 .fetch('DBParameterGroups', [])
rescue AwsCli::Error => e
  warn e.message
  exit 1
end
# 名前を指定して引いているため応答は 1 件のはずである。0 件・複数件は前提が崩れているので落とす。
unless groups.length == 1
  warn "expected exactly one DB parameter group for #{target_name}, got #{groups.length}"
  exit 1
end
actual_name = groups[0]['DBParameterGroupName'].to_s
actual_family = groups[0]['DBParameterGroupFamily'].to_s
# 8.4.10 → mysql8.4。パッチバージョンはファミリー名に含まれない。
expected_family = "mysql#{target_version.split('.').first(2).join('.')}"
verdict = actual_name == target_name && actual_family == expected_family ? 'PASS' : 'FAIL'

File.write(File.join(output_dir, 'target-parameter-group-check.md'), <<~MD)
  # 構築前チェック: 移行先 DB パラメータグループ

  - 対象名: `#{target_name}`
  - RDS が返した名前: `#{actual_name}`
  - 期待ファミリー: `#{expected_family}`
  - RDS が返したファミリー: `#{actual_family}`
  - 判定: #{verdict}
MD

if verdict != 'PASS'
  warn 'target DB parameter group does not match the configured name or engine family'
  exit 1
end
puts "Target DB parameter group check passed. Artifacts: #{output_dir}"
