#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 4 補助: Green DB の実効値を収集する。AWS API は呼び出さない。
#
# 収集そのものは Go のバイナリ（scripts/collect_green_runtime_values/）が行う。
# **MySQL クライアントは使わない。**VerifyGreen は RDS のある VPC 内で動かす場合があり、
# そこから apt リポジトリへ到達できないため実行時に導入できない。加えて
# aws/codebuild/standard:7.0 は mysql クライアントを含まない。
#
# このスクリプトの役目は次の 2 つだけである。
#   - バイナリの場所を決める（CI は事前ビルド済みを受け取り、ここではビルドしない）
#   - パスワードを環境変数で渡す。空なら対話入力を促す
#
# 収集対象のパラメータ名は、バイナリが CloudFormation テンプレートから直接読む
# （短縮記法 !Ref / !Sub の正規化を含む。scripts/internal/cfn）。
#
# 同じ内容のシェル版 collect_green_runtime_values.sh を残してある。
# **どちらを変えても、もう一方へ同じ変更を入れる。**
require 'io/console'
require 'optparse'
require 'tmpdir'

USAGE = 'Usage: collect_green_runtime_values.rb --template FILE --host HOST --user USER --output FILE ' \
        '[--collector FILE] [--port PORT] [--password-env NAME] [--ssl-ca FILE]'

options = { password_env: 'MYSQL_PASSWORD' }
# 収集に使うビルド済みバイナリ。未指定ならその場でビルドする（ローカル実行用）。
options[:collector] = ENV['GREEN_RUNTIME_COLLECTOR'].to_s

parser = OptionParser.new do |opts|
  opts.banner = USAGE
  opts.on('--template FILE') { |v| options[:template] = v }
  opts.on('--collector FILE') { |v| options[:collector] = v }
  opts.on('--host HOST') { |v| options[:host] = v }
  opts.on('--port PORT') { |v| options[:port] = v }
  opts.on('--user USER') { |v| options[:user] = v }
  opts.on('--output FILE') { |v| options[:output] = v }
  opts.on('--password-env NAME') { |v| options[:password_env] = v }
  opts.on('--ssl-ca FILE') { |v| options[:ssl_ca] = v }
  opts.on('-h', '--help') { puts opts; exit 0 }
end
begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn USAGE
  exit 2
end

%i[template host user output].each do |key|
  next unless options[key].to_s.empty?
  warn USAGE
  exit 2
end

# **CI ではビルド済みバイナリを受け取る。**VerifyGreen は Go も外部ネットワークも
# 持たない前提なので、ここでビルドしない。未指定のローカル実行でだけその場でビルドする。
built_collector = nil
if options[:collector].to_s.empty?
  unless system('command -v go >/dev/null 2>&1')
    warn '実効値の収集バイナリが指定されておらず、Go も見つからない。'
    warn 'GREEN_RUNTIME_COLLECTOR か --collector でビルド済みバイナリを渡すこと。'
    exit 1
  end
  repository_root = File.expand_path('..', __dir__)
  built_collector = File.join(Dir.tmpdir, "green-runtime-collector-#{Process.pid}")
  at_exit { File.unlink(built_collector) if built_collector && File.exist?(built_collector) }
  unless system('go', '-C', repository_root, 'build', '-o', built_collector,
                './scripts/collect_green_runtime_values')
    warn '収集バイナリのビルドに失敗した。'
    exit 1
  end
  options[:collector] = built_collector
end

collect_args = [
  '--template', options[:template],
  '--host', options[:host],
  '--user', options[:user],
  '--output', options[:output],
  '--password-env', options[:password_env],
]
collect_args += ['--port', options[:port]] unless options[:port].to_s.empty?
# 未指定ならバイナリへ焼き込んだ RDS のトラストストアを使う。
collect_args += ['--ssl-ca', options[:ssl_ca]] unless options[:ssl_ca].to_s.empty?

# パスワードは環境変数だけで渡す。コマンド引数・成果物には出力しない。
# 空の場合（auth_method: prompt）はここで対話入力を促す。エコーしない。
environment = {}
if ENV[options[:password_env]].to_s.empty?
  $stderr.print "MySQL password for #{options[:user]}@#{options[:host]}: "
  interactive_password = $stdin.noecho(&:gets).to_s.chomp
  $stderr.puts
  environment['MYSQL_PASSWORD_INTERACTIVE'] = interactive_password
  collect_args += ['--password-env', 'MYSQL_PASSWORD_INTERACTIVE']
end

# [DB 読み取り] performance_schema.global_variables から実効値を取る。変更は行わない。
# 収集バイナリの終了コードをそのまま返す。
system(environment, options[:collector], *collect_args)
status = $?.exitstatus
exit(status.nil? ? 1 : status)
