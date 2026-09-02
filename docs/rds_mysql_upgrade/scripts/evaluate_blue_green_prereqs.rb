#!/usr/bin/env ruby
# frozen_string_literal: true
# collect_blue_green_prereqs.sh の JSON をローカルで評価する。AWS API は呼ばない。
require 'json'
require 'optparse'

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: evaluate_blue_green_prereqs.rb --input-dir DIR'
  parser.on('--input-dir DIR') { |value| options[:input_dir] = value }
  parser.on('-h', '--help') { puts parser; exit }
end.parse!
abort '--input-dir is required.' unless options[:input_dir]

def read_json(dir, filename)
  JSON.parse(File.read(File.join(dir, filename)))
rescue Errno::ENOENT
  abort "Missing #{filename}; run the collector again."
end

dir = options[:input_dir]
metadata = read_json(dir, 'metadata.json')
instance = read_json(dir, 'db-instance.json').fetch('DBInstances').first
instances = read_json(dir, 'all-db-instances.json').fetch('DBInstances')
parameters = read_json(dir, 'db-parameters.json').fetch('Parameters')
option_group = read_json(dir, 'option-group.json').fetch('OptionGroupsList').first
orderable = read_json(dir, 'orderable-classes.json').fetch('OrderableDBInstanceOptions')
proxies = read_json(dir, 'db-proxies.json').fetch('DBProxies')
proxy_targets = Dir[File.join(dir, 'db-proxy-targets-*.json')].flat_map do |path|
  JSON.parse(File.read(path)).fetch('Targets', [])
end
integrations = read_json(dir, 'integrations.json').fetch('Integrations')
storage = read_json(dir, 'free-storage-space.json').fetch('Datapoints')

results = []
def add(results, status, item, detail)
  results << [status, item, detail]
end

backup = instance.fetch('BackupRetentionPeriod', 0)
add(results, backup >= 1 ? 'PASS' : 'STOP', '0-1-01 自動バックアップ', "BackupRetentionPeriod=#{backup}")

binlog = parameters.find { |parameter| parameter['ParameterName'] == 'binlog_format' }
binlog_value = binlog && binlog['ParameterValue']
binlog_status = binlog_value == 'ROW' ? 'PASS' : 'REVIEW'
binlog_detail = if binlog_value == 'ROW'
                  'ROW（Green 作成の必須条件ではないが、運用方針と一致）'
                else
                  "#{binlog_value || '取得不可'}（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断）"
                end
add(results, binlog_status, '0-1-02 binlog_format', binlog_detail)

statuses = instance.fetch('DBParameterGroups', []).map { |group| group['ParameterApplyStatus'] }.uniq
add(results, statuses == ['in-sync'] ? 'PASS' : 'STOP', '0-1-05 パラメータ適用状態', statuses.join(', '))

option_name = instance.fetch('OptionGroupMemberships').first.fetch('OptionGroupName')
add(results, option_name.start_with?('default:') ? 'PASS' : 'STOP', '0-1-03 オプショングループ', option_name)

options_set = option_group.fetch('Options', []).map { |option| option['OptionName'] }
add(results, options_set.include?('MEMCACHED') ? 'STOP' : 'PASS', '0-1-04 MEMCACHED', options_set.empty? ? '設定なし' : options_set.join(', '))

add(results, 'REVIEW', '0-1-06 外部 binlog レプリカ', 'AWS CLI のみでは判定不可。SHOW REPLICA STATUS\\G の結果が空であることを手動確認')

child_ids = instance.fetch('ReadReplicaDBInstanceIdentifiers', [])
children = instances.select { |child| child_ids.include?(child['DBInstanceIdentifier']) || child_ids.include?(child['DBInstanceArn']) }
cascade = children.any? { |child| !child.fetch('ReadReplicaDBInstanceIdentifiers', []).empty? }
add(results, cascade ? 'STOP' : 'PASS', '0-1-07 カスケードリードレプリカ', cascade ? '配下レプリカにさらに配下レプリカあり' : "直接配下=#{child_ids.length}")

db_class = instance.fetch('DBInstanceClass')
available = orderable.any? { |entry| entry['DBInstanceClass'] == db_class }
add(results, available ? 'PASS' : 'STOP', '0-1-08 インスタンスクラス', "#{db_class} / target=#{metadata['target_engine_version']}")

minimum = storage.map { |point| point['Minimum'].to_f }.min
storage_detail = minimum ? format('直近1時間の最小値: %.2f GiB', minimum / 1024**3) : 'メトリクス取得なし'
add(results, minimum && minimum >= 2 * 1024**3 ? 'PASS' : 'REVIEW', '0-1-09 空きストレージ', storage_detail)

managed_password = instance['ManageMasterUserPassword'] || !instance['MasterUserSecret'].nil?
add(results, managed_password ? 'REVIEW' : 'PASS', '0-1-10 Secrets Manager 管理パスワード', managed_password ? '利用あり。制約と再設定手順を確認' : '利用なし')

db_arn = instance['DBInstanceArn']
related = integrations.select { |integration| [integration['SourceArn'], integration['TargetArn']].include?(db_arn) }
add(results, related.empty? ? 'PASS' : 'REVIEW', '0-1-11 Zero-ETL 統合', related.empty? ? '関連統合なし' : related.map { |entry| entry['IntegrationArn'] }.join(', '))

cross_region = child_ids.any? { |id| id.start_with?('arn:') && id.split(':')[3] != db_arn.split(':')[3] }
add(results, cross_region ? 'REVIEW' : 'PASS', '0-1-12 クロスリージョンリードレプリカ', cross_region ? '関連 ARN を確認' : '検出なし')

resource_id = instance['DbiResourceId']
proxy_registered = proxy_targets.any? { |target| target['RdsResourceId'] == resource_id }
proxy_detail = if proxies.empty?
                 'このリージョンに Proxy なし'
               elsif proxy_registered
                 "対象 Blue は Proxy ターゲットに登録済み（#{proxies.map { |proxy| proxy['DBProxyName'] }.join(', ')}）"
               else
                 "Proxy=#{proxies.map { |proxy| proxy['DBProxyName'] }.join(', ')}。対象 Blue の登録なし"
               end
add(results, proxies.empty? || proxy_registered ? 'PASS' : 'REVIEW', '0-1-13 RDS Proxy', proxy_detail)
iam_auth = instance['IAMDatabaseAuthenticationEnabled']
add(results, iam_auth ? 'REVIEW' : 'PASS', '0-1-14 IAM DB 認証', iam_auth ? '有効。Green 用リソース ID の IAM ポリシー更新手順を確認' : '無効')

puts "Blue/Green 成立条件チェック: #{instance['DBInstanceIdentifier']}"
puts "収集日時: #{metadata['collected_at']} / 判定対象: #{metadata['target_engine_version']}"
puts format('%-8s %-30s %s', 'STATUS', 'ITEM', 'DETAIL')
puts '-' * 100
results.each { |status, item, detail| puts format('%-8s %-30s %s', status, item, detail) }
stops = results.count { |status, _item, _detail| status == 'STOP' }
reviews = results.count { |status, _item, _detail| status == 'REVIEW' }
puts "結果: STOP=#{stops}, REVIEW=#{reviews}"
exit(stops.zero? ? 0 : 1)
