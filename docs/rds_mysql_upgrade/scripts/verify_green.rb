#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 4: Green の RDS 構成と ReplicaLag を検証する。buildspec（ci/codebuild/verify-green.yml）
# から `ruby` で直接呼ぶ。**判定はここでは持たない**——材料をそろえて Go の判定器へ渡す。
#
#   1. 設定を読む（宣言値・テンプレートのパス・リージョン）
#   2. 移行フェーズを観測する（lib/migration_phase.rb）。切替済みなら検証対象は無いので、
#      何もせず成功する（後始末フェーズで再実行しても落ちないように）
#   3. 検証に要る AWS の状態を集めて --output-dir へ書く（lib/green_state.rb）。
#      Deployment が無い／AVAILABLE でなければここで止まる
#   4. Green の MySQL 実効値を集める（collect_green_runtime_values.rb。任意）。
#      --runtime-values-file を渡せば収集しない
#   5. 判定器（Go の generate_green_verification_report）を --check と --output で呼ぶ。
#      不適合ならレポートの「0. 検証結果」に出たうえで終了コード 1。バイナリの場所は
#      lib/resolve_green_tools.rb が決める（CI は GREEN_REPORT_GENERATOR で受け取り、
#      指定の無いローカル実行でだけその場でビルドする）
#
# AWS は読み取りだけで、SDK ではなく AWS CLI を exec する（lib/aws_cli.rb）。
# 終了コード: 0 検証を通った、または検証対象なし / 1 不適合・材料がそろわない / 2 引数の誤り
require 'fileutils'
require 'optparse'
require 'rbconfig'
require 'tmpdir'

require_relative 'lib/aws_cli'
require_relative 'lib/deployment_config'
require_relative 'lib/green_state'
require_relative 'lib/migration_phase'
require_relative 'lib/resolve_green_tools'

USAGE = 'Usage: verify_green.rb --config FILE --service NAME [--output-dir DIR] ' \
        '[--region REGION] [--profile PROFILE] [--runtime-values-file FILE | --mysql-user USER [--mysql-password-env NAME]]'

options = { region: '', profile: '', runtime_values_file: '', mysql_user: '', mysql_password_env: 'MYSQL_PASSWORD' }
parser = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on('--config FILE') { |v| options[:config] = v }
  opts.on('--service NAME') { |v| options[:service] = v }
  opts.on('--output-dir DIR') { |v| options[:output_dir] = v }
  opts.on('--region REGION', '空なら設定ファイルの aws_region') { |v| options[:region] = v }
  opts.on('--profile PROFILE', '空なら設定ファイルの aws_profile') { |v| options[:profile] = v }
  opts.on('--runtime-values-file FILE', '収集済みの MySQL 実効値（渡すと収集しない）') { |v| options[:runtime_values_file] = v }
  opts.on('--mysql-user USER', '実効値の収集で設定より優先する接続ユーザー') { |v| options[:mysql_user] = v }
  opts.on('--mysql-password-env NAME', 'パスワードを載せた環境変数（--mysql-user 用）') { |v| options[:mysql_password_env] = v }
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

  warn "--#{key.to_s.tr('_', '-')} is required."
  warn USAGE
  exit 2
end
output_dir = options[:output_dir].to_s
output_dir = Dir.mktmpdir('rds-bg-verify') if output_dir.empty?
FileUtils.mkdir_p(output_dir)

begin
  # --- 1. 設定 -------------------------------------------------------------
  config = DeploymentConfig.load(options[:config])
  service = config.service(options[:service])
  target_engine_version = service.required('target_engine_version')
  target_instance_class = service.required('target_db_instance_class')
  target_parameter_group = service.required('target_db_parameter_group_name')
  template = service.required('target_parameter_group_template_path')
  region = options[:region].empty? ? config.required('aws_region') : options[:region]
  profile = options[:profile].empty? ? config.optional('aws_profile') : options[:profile]
  aws = AwsCli.new(region: region, profile: profile)

  # --- 2. 移行フェーズ ---------------------------------------------------------
  # 切替後は移行元識別子が green（新 Blue）を指し、Deployment は既に SWITCHOVER_COMPLETED である。
  seen = MigrationPhase.observe(config, options[:service], aws, save: File.join(output_dir, 'source.json'))
  if seen.phase == MigrationPhase::POST
    puts "Already switched over: #{seen.source_id} is #{seen.current_version} with #{seen.current_group}."
    puts 'Green の検証は切替前に行うものであり、検証対象はない。'
    exit 0
  end
  if seen.phase == MigrationPhase::UNKNOWN
    warn '移行元が移行前・移行後のいずれの宣言とも一致しない。検証は続けるが、設定と実状態を確認する。'
    warn MigrationPhase.describe_inputs(seen.current_version, seen.current_group, *seen.declared)
  end

  # --- 3. AWS の状態 -----------------------------------------------------------
  # Deployment を source の ARN で引き当て、Green・パラメータ 3 種・レプリカ遅延を書き出す。
  state = GreenState.collect(region: region, profile: profile, source_id: seen.source_id,
                             target_parameter_group: target_parameter_group, output_dir: output_dir)
rescue DeploymentConfig::Error, AwsCli::Error, GreenState::Error => e
  warn e.message
  exit 1
end

# --- 4. MySQL 実効値（任意） ---------------------------------------------------
# 収集するか・接続情報の解決は collect_green_runtime_values.rb が設定の mysql_verification を
# 読んで決める。無効なら何もせず、出力ファイルも作らない。対話入力があり得るので別プロセスにする。
runtime_values = options[:runtime_values_file]
if runtime_values.empty?
  runtime_path = File.join(output_dir, 'green-runtime-values.json')
  FileUtils.rm_f(runtime_path) # 前回の結果を今回の結果と取り違えないため
  command = [RbConfig.ruby, File.join(__dir__, 'collect_green_runtime_values.rb'),
             '--config', options[:config], '--service', options[:service], '--host', state.green_endpoint,
             '--region', region, '--profile', profile, '--output', runtime_path]
  command += ['--mysql-user', options[:mysql_user], '--mysql-password-env', options[:mysql_password_env]] unless options[:mysql_user].empty?
  unless system(*command)
    warn 'MySQL 実効値の収集に失敗した。'
    exit 1
  end
  runtime_values = File.exist?(runtime_path) ? runtime_path : ''
end

# --- 5. 判定とレポート（Go。--check と --output の併用） -------------------------
# CloudFormation テンプレートの読み取り（scripts/internal/cfn）を実効値の収集器と
# 共有するため、判定は Go に置いている。
begin
  generator = GreenTools.resolve_or_build(GreenTools.tool('generate_green_verification_report'))
rescue GreenTools::Error => e
  warn e.message
  exit 1
end
report_args = ['--check', '--input-dir', output_dir, '--template', template,
               '--expect-engine-version', target_engine_version,
               '--expect-instance-class', target_instance_class,
               '--expect-parameter-group', target_parameter_group,
               '--output', File.join(output_dir, 'green-verification-report.md')]
report_args += ['--runtime-values', runtime_values] unless runtime_values.empty?
passed = system(generator, *report_args)
puts "Artifacts: #{output_dir}"
unless passed
  warn 'VERIFY FAILED: レポートの「0. 検証結果」を確認する。'
  exit 1
end
puts "VERIFY PASSED: #{state.deployment_id}"
