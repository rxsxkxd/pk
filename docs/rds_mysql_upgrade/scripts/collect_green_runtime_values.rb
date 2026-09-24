#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 4 補助: Green DB の MySQL 実効値を収集する。レポートにのみ載せ、判定には使わない。
#
# 設定ファイルの mysql_verification を読み、**収集するかどうか・接続情報の解決・収集の実行**
# までをここで行う。verify_green.sh は `--config` と `--service` と Green のエンドポイントを
# 渡すだけでよい。
#
#   mysql_verification.enabled が false   … 何もせず終了コード 0（出力ファイルを作らない）
#   auth_method: parameter_store           … SSM Parameter Store からパスワードとユーザー名を取る
#   auth_method: plaintext                 … 設定ファイルの値（テスト環境専用。production では拒否）
#   auth_method: prompt                    … 対話入力（エコーしない。ローカル専用）
#   --mysql-user を指定                    … 設定より優先し、パスワードは --mysql-password-env の
#                                            環境変数から取る（後方互換。enabled も true 扱い）
#
# 設定の検証（auth_method の値、plaintext の production 拒否、必須項目）は
# lib/deployment_config.rb の mysql_verification が行う。
#
# 収集そのものは Go のバイナリ（scripts/collect_green_runtime_values/）が行う。
# **MySQL クライアントは使わない**（VerifyGreen は VPC 内から apt へ到達できず、
# aws/codebuild/standard:7.0 は mysql クライアントを含まない）。バイナリの場所は
# lib/resolve_green_tools.rb が決め、ローカルで見つからなければその場でビルドする。
#
# **パスワードは環境変数だけで Go のバイナリへ渡す。**コマンド引数・標準出力・成果物には出さない。
# AWS は SSM の読み取り（ssm:GetParameter）だけを呼ぶ。
require 'io/console'
require 'optparse'

require_relative 'lib/aws_cli'
require_relative 'lib/deployment_config'
require_relative 'lib/resolve_green_tools'

USAGE = 'Usage: collect_green_runtime_values.rb --config FILE --service NAME --host HOST --output FILE ' \
        '[--region REGION] [--profile PROFILE] [--mysql-user USER] [--mysql-password-env NAME]'

options = { region: '', profile: '', mysql_user: '', mysql_password_env: 'MYSQL_PASSWORD' }
parser = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on('--config FILE') { |v| options[:config] = v }
  opts.on('--service NAME') { |v| options[:service] = v }
  opts.on('--host HOST', 'Green のエンドポイント') { |v| options[:host] = v }
  opts.on('--output FILE') { |v| options[:output] = v }
  opts.on('--region REGION', 'AWS Region（設定ファイルの aws_region を上書き）') { |v| options[:region] = v }
  opts.on('--profile PROFILE') { |v| options[:profile] = v }
  opts.on('--mysql-user USER', '設定より優先する接続ユーザー') { |v| options[:mysql_user] = v }
  # 説明文を `--` で始めない。OptionParser は `--` で始まる引数を別のオプション定義として
  # 解釈し、--mysql-user の扱いが壊れる。
  opts.on('--mysql-password-env NAME', 'パスワードを載せた環境変数（--mysql-user 用。default: MYSQL_PASSWORD）') do |v|
    options[:mysql_password_env] = v
  end
  opts.on('-h', '--help') { puts opts; exit 0 }
end
begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn USAGE
  exit 2
end
%i[config service host output].each do |key|
  next unless options[key].to_s.empty?

  warn "--#{key} is required."
  warn USAGE
  exit 2
end

begin
  config = DeploymentConfig.load(options[:config])
  service = config.service(options[:service])
  template = service.required('target_parameter_group_template_path')
  verification = config.mysql_verification(options[:service])
  region = options[:region].empty? ? config.required('aws_region') : options[:region]
  profile = options[:profile].empty? ? config.optional('aws_profile') : options[:profile]
rescue DeploymentConfig::Error => e
  warn e.message
  exit 1
end

# 収集の有効・無効と接続方式をログへ残す。ユーザー名・パラメータ名・パスワードは出さない。
auth = verification['MYSQL_VERIFY_AUTH']
enabled = verification['MYSQL_VERIFY_ENABLED'] == 'true'
puts "mysql_verification.enabled=#{enabled} auth_method=#{auth}"

# --- 接続情報の解決 ---------------------------------------------------------
user = verification['MYSQL_VERIFY_USER']
if !options[:mysql_user].empty?
  puts 'mysql_verification: --mysql-user の指定により、呼び出し側の接続情報で収集する。'
  user = options[:mysql_user]
  password = ENV[options[:mysql_password_env]].to_s
elsif !enabled
  exit 0
else
  case auth
  when 'parameter_store'
    # [読み取り] SSM Parameter Store の SecureString。ユーザー名も秘匿側から取る。
    aws = AwsCli.new(region: region, profile: profile)
    fetch = lambda do |name|
      aws.run('ssm', 'get-parameter', '--name', name, '--with-decryption',
              '--query', 'Parameter.Value', '--output', 'text').chomp
    end
    begin
      password = fetch.(verification['MYSQL_VERIFY_PARAMETER_NAME'])
      user = fetch.(verification['MYSQL_VERIFY_USER_PARAMETER_NAME'])
    rescue AwsCli::Error => e
      warn e.message
      exit 1
    end
  when 'plaintext'
    password = verification['MYSQL_VERIFY_PLAINTEXT']
    warn 'WARNING: auth_method: plaintext を使用している。設定ファイルは Git 追跡対象であるため、テスト環境専用とすること。'
  when 'prompt'
    password = ''
  end
end
if user.to_s.empty?
  warn "MySQL の接続ユーザー名を解決できなかった（auth_method: #{auth}）。"
  warn 'config の mysql_verification.user か、user_parameter_name の値を確認する。'
  exit 1
end
# 空（auth_method: prompt など）なら対話入力を促す。エコーしない。
if password.to_s.empty?
  unless $stdin.tty?
    warn "MySQL のパスワードが無く、端末も無いので対話入力できない（auth_method: #{auth}）。"
    warn "CI では auth_method: parameter_store を使うこと。"
    exit 1
  end
  $stderr.print "MySQL password for #{user}@#{options[:host]}: "
  password = $stdin.noecho(&:gets).to_s.chomp
  $stderr.puts
end

# --- 収集 -------------------------------------------------------------------
begin
  collector = GreenTools.resolve_or_build(GreenTools.tool('collect_green_runtime_values'))
rescue GreenTools::Error => e
  warn e.message
  exit 1
end
collect_args = ['--template', template, '--host', options[:host], '--user', user,
                '--port', verification['MYSQL_VERIFY_PORT'],
                '--output', options[:output], '--password-env', 'MYSQL_VERIFY_PASSWORD']
# TLS は常に検証する（VERIFY_CA 相当）。未指定ならバイナリ内蔵の RDS トラストストアを使う。
ssl_ca = verification['MYSQL_VERIFY_SSL_CA']
collect_args += ['--ssl-ca', ssl_ca] unless ssl_ca.empty?

# [DB 読み取り] performance_schema.global_variables から実効値を取る。変更は行わない。
# 収集バイナリの終了コードをそのまま返す。
system({ 'MYSQL_VERIFY_PASSWORD' => password }, collector, *collect_args)
exit($?.exitstatus || 1)
