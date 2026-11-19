# frozen_string_literal: true

# 環境のタグで更新対象サーバーを引き、SSM に登録されていて応答する台だけを、インスタンスの一覧ファイルに書き出す（読み取りだけ）。
# 列は「インスタンス ID・パブリック IP・Name タグ」（タブ区切り）。人が目で確かめて要らない行を消してから、refresh_rules.rb に渡す。
#
#   ruby rb/list_instances.rb --env staging [--tag-key Environment] [--tag-value staging] [--out FILE] [--overwrite]
#                             [--profile NAME] [--region NAME]
#
# 終了コード: 0 書き出した / 2 使い方・前提の誤り / 3 AWS のエラー
require 'time'
require_relative 'lib/cli'

options = Cli.parse_options(tag_key: 'Environment') do |parser, opts|
  parser.banner = 'usage: ruby rb/list_instances.rb --env <環境> [options]'
  parser.on('--env NAME', Cli::ENVIRONMENTS, "環境（#{Cli::ENVIRONMENTS.join('・')}）") { |value| opts[:env] = value }
  parser.on('--tag-key KEY', '環境のタグのキー（既定 Environment）') { |value| opts[:tag_key] = value }
  parser.on('--tag-value VALUE', '環境のタグの値（既定は環境の名前）') { |value| opts[:tag_value] = value }
  parser.on('--out FILE', 'インスタンスの一覧ファイル（既定 instance-lists/<環境>.tsv）') { |value| opts[:out] = value }
  parser.on('--overwrite', '同じ名前のファイルがあっても上書きする') { opts[:overwrite] = true }
end
Cli.usage_error('--env を指定する') unless options[:env]
Cli.require_aws_cli
tag_value = options[:tag_value] || options[:env]
out_path = options[:out] || Cli.default_list_path(options[:env])
if File.exist?(out_path) && !options[:overwrite]
  Cli.usage_error("#{out_path} がすでにある（人が確かめた後の一覧を消さないため、上書きしない。作り直すときは --overwrite）")
end

begin
  # 1. 環境のタグが合い、動いている台
  result = AwsCli.run('ec2', 'describe-instances',
                      '--filters', "Name=tag:#{options[:tag_key]},Values=#{tag_value}",
                      'Name=instance-state-name,Values=running')
  instances = result['Reservations'].flat_map { |reservation| reservation['Instances'] }

  # 2. SSM に登録されていて応答する台（Run Command を受け付ける台）
  info = AwsCli.run('ssm', 'describe-instance-information', '--filters', 'Key=PingStatus,Values=Online')
  online_ids = info['InstanceInformationList'].map { |item| item['InstanceId'] }
rescue AwsCli::Error => e
  warn "AWS のエラー: #{e.summary}"
  exit 3
end

rows = instances.map do |instance|
  name = (instance['Tags'] || []).find { |tag| tag['Key'] == 'Name' }&.fetch('Value', nil)
  [instance['InstanceId'], instance['PublicIpAddress'] || '-', name.to_s.empty? ? '-' : name]
end.sort_by { |row| [row[2], row[0]] }
targets, excluded = rows.partition { |row| online_ids.include?(row[0]) }

lines = ["# 環境: #{options[:env]}（タグ #{options[:tag_key]}=#{tag_value}）。#{Time.now.strftime('%F %T')} に list_instances.rb が作成",
         "# instance_id\tpublic_ip\tname"] + targets.map { |row| row.join("\t") }
Dir.mkdir(File.dirname(out_path)) unless Dir.exist?(File.dirname(out_path))
File.write(out_path, "#{lines.join("\n")}\n")

puts lines
puts
excluded.each { |row| puts "外した（SSM で応答しない）: #{row.join("\t")}" }
puts "書き出した: #{out_path}（#{targets.size} 台。外した台 #{excluded.size} 台）"
puts '目で確かめ、要らない行を消してから refresh_rules.rb に渡す' unless targets.empty?
