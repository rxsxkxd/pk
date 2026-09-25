#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 4 の準備: verify_green.sh から呼ばれ、判定器（Go の generate_green_verification_report）へ
# 渡す材料をそろえる。**判定はしない。**
#
#   1. 設定を読む（宣言値・テンプレートのパス・リージョン）
#   2. 移行フェーズを観測する（lib/migration_phase.rb）。切替済みなら検証対象は無いので、
#      VERIFY=skip を返して終わる（後始末フェーズで再実行しても落ちないように）
#   3. 検証に要る AWS の状態を集めて --output-dir へ書く（lib/green_state.rb）。
#      Deployment が無い／AVAILABLE でなければここで止まる
#   4. Green の MySQL 実効値を集める（collect_green_runtime_values.rb。任意）。
#      --runtime-values-file を渡せば収集しない
#
# 標準出力には、呼び出し側が変数へ受けてから eval する代入行だけを出す。
# 進み具合と理由は標準エラーへ出す（実効値の収集が出す案内や対話入力も標準エラーへ回す）。
#
#   VERIFY                   run / skip
#   DEPLOYMENT_ID            引き当てた Blue/Green Deployment
#   TEMPLATE                 移行先パラメータグループの CloudFormation テンプレート
#   EXPECT_ENGINE_VERSION / EXPECT_INSTANCE_CLASS / EXPECT_PARAMETER_GROUP  設定の宣言値
#   RUNTIME_VALUES           MySQL 実効値の JSON（収集しなかったら空）
#
# AWS は読み取りだけで、SDK ではなく AWS CLI を exec する（lib/aws_cli.rb）。
# 終了コード: 0 材料がそろった、または検証対象なし / 1 そろわない / 2 引数の誤り
require 'fileutils'
require 'optparse'
require 'rbconfig'
require 'shellwords'

require_relative 'lib/aws_cli'
require_relative 'lib/deployment_config'
require_relative 'lib/green_state'
require_relative 'lib/migration_phase'

USAGE = 'Usage: prepare_green_verification.rb --config FILE --service NAME --output-dir DIR ' \
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
%i[config service output_dir].each do |key|
  next unless options[key].to_s.empty?

  warn "--#{key.to_s.tr('_', '-')} is required."
  warn USAGE
  exit 2
end
output_dir = options[:output_dir]
FileUtils.mkdir_p(output_dir)

def emit(values)
  values.each { |name, value| puts "#{name}=#{Shellwords.escape(value.to_s)}" }
end

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
    warn "Already switched over: #{seen.source_id} is #{seen.current_version} with #{seen.current_group}."
    warn 'Green の検証は切替前に行うものであり、検証対象はない。'
    emit('VERIFY' => 'skip')
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
# 読んで決める。無効なら何もせず、出力ファイルも作らない。対話入力があり得るので別プロセスにし、
# その標準出力は標準エラーへ回す（こちらの標準出力は代入行専用のため）。
runtime_values = options[:runtime_values_file]
if runtime_values.empty?
  runtime_path = File.join(output_dir, 'green-runtime-values.json')
  FileUtils.rm_f(runtime_path) # 前回の結果を今回の結果と取り違えないため
  command = [RbConfig.ruby, File.join(__dir__, 'collect_green_runtime_values.rb'),
             '--config', options[:config], '--service', options[:service], '--host', state.green_endpoint,
             '--region', region, '--profile', profile, '--output', runtime_path]
  command += ['--mysql-user', options[:mysql_user], '--mysql-password-env', options[:mysql_password_env]] unless options[:mysql_user].empty?
  unless system(*command, out: $stderr)
    warn 'MySQL 実効値の収集に失敗した。'
    exit 1
  end
  runtime_values = File.exist?(runtime_path) ? runtime_path : ''
end

emit('VERIFY' => 'run', 'DEPLOYMENT_ID' => state.deployment_id, 'TEMPLATE' => template,
     'EXPECT_ENGINE_VERSION' => target_engine_version, 'EXPECT_INSTANCE_CLASS' => target_instance_class,
     'EXPECT_PARAMETER_GROUP' => target_parameter_group, 'RUNTIME_VALUES' => runtime_values)
