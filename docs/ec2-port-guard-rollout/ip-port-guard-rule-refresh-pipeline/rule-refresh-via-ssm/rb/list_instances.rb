# frozen_string_literal: true

# 環境のタグで更新対象サーバーを引き、SSM に登録されていて応答する台だけを、インスタンスの一覧ファイルに書き出す（読み取りだけ）。
# 列は「インスタンス ID・パブリック IP・Name タグ」（タブ区切り）。人が目で確かめて要らない行を消してから、refresh_rules.rb に渡す。
# --hosted-zone-id（と --server-list）を付けると、Route 53 の名前と DB のサーバーリストとも照合し、合わないところを警告として
# 表示し、一覧ファイルにも「# 警告:」の行で書く。一覧に入れる台は変えない（README の「サーバーリストとの照合」）。
#
#   ruby rb/list_instances.rb --env staging [--tag-key Environment] [--tag-value staging] [--out FILE] [--overwrite]
#                             [--hosted-zone-id ID ...] [--server-list FILE] [--type-tag-key KEY]
#                             [--server-list-host-column NAME] [--server-list-type-column NAME]
#                             [--profile NAME] [--region NAME]
#
# 終了コード: 0 書き出した（警告があっても 0）/ 2 使い方・前提の誤り / 3 AWS のエラー
require 'time'
require_relative 'lib/cli'
require_relative 'lib/server_list_check'

# 照合の既定値。決まったらここを直す（オプションで毎回上書きもできる）。
TYPE_TAG_KEY = '' # EC2 の分類のタグのキー（未確定。空なら --type-tag-key を付けない限り、分類は比べない）
SERVER_LIST_HOST_COLUMN = 'host' # DB のサーバーリスト（TSV）のホスト名の列（見出しの名前）
SERVER_LIST_TYPE_COLUMN = 'type' # DB のサーバーリスト（TSV）のサーバータイプの列（見出しの名前）

options = Cli.parse_options(tag_key: 'Environment', hosted_zone_ids: [], type_tag_key: TYPE_TAG_KEY,
                            host_column: SERVER_LIST_HOST_COLUMN, type_column: SERVER_LIST_TYPE_COLUMN) do |parser, opts|
  parser.banner = 'usage: ruby rb/list_instances.rb --env <環境> [options]'
  parser.on('--env NAME', Cli::ENVIRONMENTS, "環境（#{Cli::ENVIRONMENTS.join('・')}）") { |value| opts[:env] = value }
  parser.on('--tag-key KEY', '環境のタグのキー（既定 Environment）') { |value| opts[:tag_key] = value }
  parser.on('--tag-value VALUE', '環境のタグの値（既定は環境の名前）') { |value| opts[:tag_value] = value }
  parser.on('--out FILE', 'インスタンスの一覧ファイル（既定 instance-lists/<環境>.tsv）') { |value| opts[:out] = value }
  parser.on('--overwrite', '同じ名前のファイルがあっても上書きする') { opts[:overwrite] = true }
  parser.on('--hosted-zone-id ID', '照合: 名前を引く Route 53 のホストゾーン（何度でも指定できる）') { |value| opts[:hosted_zone_ids] << value }
  parser.on('--server-list FILE', '照合: DB のサーバーリスト（TSV。--hosted-zone-id と一緒に使う）') { |value| opts[:server_list] = value }
  parser.on('--type-tag-key KEY', "照合: EC2 の分類のタグのキー（既定 #{TYPE_TAG_KEY.empty? ? 'なし' : TYPE_TAG_KEY}）") { |value| opts[:type_tag_key] = value }
  parser.on('--server-list-host-column NAME', "照合: ホスト名の列（既定 #{SERVER_LIST_HOST_COLUMN}）") { |value| opts[:host_column] = value }
  parser.on('--server-list-type-column NAME', "照合: サーバータイプの列（既定 #{SERVER_LIST_TYPE_COLUMN}）") { |value| opts[:type_column] = value }
end
Cli.usage_error('--env を指定する') unless options[:env]
Cli.usage_error('--server-list は --hosted-zone-id と一緒に使う（Route 53 の名前を通して突き合わせる）') if options[:server_list] && options[:hosted_zone_ids].empty?
Cli.require_aws_cli
tag_value = options[:tag_value] || options[:env]
type_tag_key = options[:type_tag_key].to_s.empty? ? nil : options[:type_tag_key]
out_path = options[:out] || Cli.default_list_path(options[:env])
if File.exist?(out_path) && !options[:overwrite]
  Cli.usage_error("#{out_path} がすでにある（人が確かめた後の一覧を消さないため、上書きしない。作り直すときは --overwrite）")
end
# サーバーリストは AWS に問い合わせる前に読む（形が違えば、ここで止まる）
servers = nil
if options[:server_list]
  Cli.usage_error("サーバーリストがない: #{options[:server_list]}") unless File.exist?(options[:server_list])
  begin
    servers = ServerListCheck.read_server_list(options[:server_list], options[:host_column], options[:type_column])
  rescue ArgumentError => e
    Cli.usage_error("サーバーリストの形が違う: #{e.message}（列の名前は --server-list-host-column・--server-list-type-column で合わせる）")
  end
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

  # 3. 照合するとき: Route 53 の A レコード（エイリアスでないもの）から、IP → 名前の表を作る
  ip_names = Hash.new { |hash, key| hash[key] = [] }
  options[:hosted_zone_ids].each do |zone_id|
    records = AwsCli.run('route53', 'list-resource-record-sets', '--hosted-zone-id', zone_id)['ResourceRecordSets']
    records.select { |record| record['Type'] == 'A' && record['ResourceRecords'] }.each do |record|
      record['ResourceRecords'].each { |value| ip_names[value['Value']] |= [record['Name']] }
    end
  end
rescue AwsCli::Error => e
  warn "AWS のエラー: #{e.summary}"
  exit 3
end

tag = ->(instance, key) { (instance['Tags'] || []).find { |item| item['Key'] == key }&.fetch('Value', nil) }
checked = instances.map do |instance|
  name = tag.call(instance, 'Name').to_s
  { id: instance['InstanceId'], label: name.empty? ? '-' : name, public_ip: instance['PublicIpAddress'],
    type: type_tag_key && tag.call(instance, type_tag_key) }
end
check = !options[:hosted_zone_ids].empty?
dns_names, warnings = check ? ServerListCheck.check(checked, ip_names, servers, type_tag_key) : [{}, []]

rows = checked.map do |instance|
  row = [instance[:id], instance[:public_ip] || '-', instance[:label]]
  check ? row + [dns_names[instance[:id]].empty? ? '-' : dns_names[instance[:id]].join(',')] : row
end.sort_by { |row| [row[2], row[0]] }
targets, excluded = rows.partition { |row| online_ids.include?(row[0]) }

columns = %w[instance_id public_ip name] + (check ? %w[dns_name] : [])
header = ["# 環境: #{options[:env]}（タグ #{options[:tag_key]}=#{tag_value}）。#{Time.now.strftime('%F %T')} に list_instances.rb が作成"]
if check
  header << "# 照合: Route 53 #{options[:hosted_zone_ids].join(', ')}" \
            "#{servers ? "、サーバーリスト #{options[:server_list]}（#{servers.size} 台）" : ''}" \
            "#{type_tag_key ? "、分類のタグ #{type_tag_key}" : '、分類は比べない'}。警告 #{warnings.size} 件（一覧に入れる台は変えていない）"
  header.concat(warnings.map { |text| "# 警告: #{text}" })
end
lines = header + ["# #{columns.join("\t")}"] + targets.map { |row| row.join("\t") }
Dir.mkdir(File.dirname(out_path)) unless Dir.exist?(File.dirname(out_path))
File.write(out_path, "#{lines.join("\n")}\n")

puts lines
puts
excluded.each { |row| puts "外した（SSM で応答しない）: #{row.join("\t")}" }
puts "警告が #{warnings.size} 件ある（上の「# 警告:」の行。一覧ファイルにも書いた）" unless warnings.empty?
puts "書き出した: #{out_path}（#{targets.size} 台。外した台 #{excluded.size} 台）"
puts '目で確かめ、要らない行を消してから refresh_rules.rb に渡す' unless targets.empty?
