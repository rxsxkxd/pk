#!/usr/bin/env ruby
# frozen_string_literal: true
# Step 1: collect_blue_green_prereqs.sh の JSON をローカルで評価する。AWS API は呼ばない。
#
# 標準出力への一覧に加え、--output で Markdown レポートも出せる。
# **このレポートはゲート①（移行できるか／どれを対象にするか）の判断材料である。**
# 判定そのものだけでなく、**何を見てそう判定したか（観測値と取得元）**を残す。
require 'json'
require 'optparse'

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: evaluate_blue_green_prereqs.rb --input-dir DIR [--output FILE]'
  parser.on('--input-dir DIR') { |value| options[:input_dir] = value }
  parser.on('--output FILE', 'Markdown レポートの出力先（省略時は標準出力のみ）') { |value| options[:output] = value }
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
# status … PASS / REVIEW / STOP
# item   … チェック項目（phase-0-precheck.md の採番に対応）
# detail … 判定の根拠になった観測値
# source … その値をどの収集ファイルから読んだか（証跡として残す）
def add(results, status, item, detail, source)
  results << [status, item, detail, source]
end

backup = instance.fetch('BackupRetentionPeriod', 0)
add(results, backup >= 1 ? 'PASS' : 'STOP', '0-1-01 自動バックアップ', "BackupRetentionPeriod=#{backup}", 'db-instance.json')

binlog = parameters.find { |parameter| parameter['ParameterName'] == 'binlog_format' }
binlog_value = binlog && binlog['ParameterValue']
binlog_status = binlog_value == 'ROW' ? 'PASS' : 'REVIEW'
binlog_detail = if binlog_value == 'ROW'
                  'ROW（Green 作成の必須条件ではないが、運用方針と一致）'
                else
                  "#{binlog_value || '取得不可'}（Blue/Green 作成の阻害要因ではない。ROW 統一は別変更として判断）"
                end
add(results, binlog_status, '0-1-02 binlog_format', binlog_detail, 'db-parameters.json')

statuses = instance.fetch('DBParameterGroups', []).map { |group| group['ParameterApplyStatus'] }.uniq
add(results, statuses == ['in-sync'] ? 'PASS' : 'STOP', '0-1-05 パラメータ適用状態', statuses.join(', '), 'db-instance.json')

option_name = instance.fetch('OptionGroupMemberships').first.fetch('OptionGroupName')
add(results, option_name.start_with?('default:') ? 'PASS' : 'STOP', '0-1-03 オプショングループ', option_name, 'db-instance.json')

options_set = option_group.fetch('Options', []).map { |option| option['OptionName'] }
add(results, options_set.include?('MEMCACHED') ? 'STOP' : 'PASS', '0-1-04 MEMCACHED', options_set.empty? ? '設定なし' : options_set.join(', '), 'option-group.json')

add(results, 'REVIEW', '0-1-06 外部 binlog レプリカ', 'AWS CLI のみでは判定不可。SHOW REPLICA STATUS\\G の結果が空であることを手動確認', '手動確認（収集対象外）')

child_ids = instance.fetch('ReadReplicaDBInstanceIdentifiers', [])
children = instances.select { |child| child_ids.include?(child['DBInstanceIdentifier']) || child_ids.include?(child['DBInstanceArn']) }
cascade = children.any? { |child| !child.fetch('ReadReplicaDBInstanceIdentifiers', []).empty? }
add(results, cascade ? 'STOP' : 'PASS', '0-1-07 カスケードリードレプリカ', cascade ? '配下レプリカにさらに配下レプリカあり' : "直接配下=#{child_ids.length}", 'all-db-instances.json')

db_class = instance.fetch('DBInstanceClass')
available = orderable.any? { |entry| entry['DBInstanceClass'] == db_class }
add(results, available ? 'PASS' : 'STOP', '0-1-08 インスタンスクラス', "#{db_class} / target=#{metadata['target_engine_version']}", 'orderable-classes.json')

minimum = storage.map { |point| point['Minimum'].to_f }.min
storage_detail = minimum ? format('直近1時間の最小値: %.2f GiB', minimum / 1024**3) : 'メトリクス取得なし'
add(results, minimum && minimum >= 2 * 1024**3 ? 'PASS' : 'REVIEW', '0-1-09 空きストレージ', storage_detail, 'free-storage-space.json')

managed_password = instance['ManageMasterUserPassword'] || !instance['MasterUserSecret'].nil?
add(results, managed_password ? 'REVIEW' : 'PASS', '0-1-10 Secrets Manager 管理パスワード', managed_password ? '利用あり。制約と再設定手順を確認' : '利用なし', 'db-instance.json')

db_arn = instance['DBInstanceArn']
related = integrations.select { |integration| [integration['SourceArn'], integration['TargetArn']].include?(db_arn) }
add(results, related.empty? ? 'PASS' : 'REVIEW', '0-1-11 Zero-ETL 統合', related.empty? ? '関連統合なし' : related.map { |entry| entry['IntegrationArn'] }.join(', '), 'integrations.json')

cross_region = child_ids.any? { |id| id.start_with?('arn:') && id.split(':')[3] != db_arn.split(':')[3] }
add(results, cross_region ? 'REVIEW' : 'PASS', '0-1-12 クロスリージョンリードレプリカ', cross_region ? '関連 ARN を確認' : '検出なし', 'db-instance.json')

resource_id = instance['DbiResourceId']
proxy_registered = proxy_targets.any? { |target| target['RdsResourceId'] == resource_id }
proxy_detail = if proxies.empty?
                 'このリージョンに Proxy なし'
               elsif proxy_registered
                 "対象 Blue は Proxy ターゲットに登録済み（#{proxies.map { |proxy| proxy['DBProxyName'] }.join(', ')}）"
               else
                 "Proxy=#{proxies.map { |proxy| proxy['DBProxyName'] }.join(', ')}。対象 Blue の登録なし"
               end
add(results, proxies.empty? || proxy_registered ? 'PASS' : 'REVIEW', '0-1-13 RDS Proxy', proxy_detail, 'db-proxies.json / db-proxy-targets-*.json')
iam_auth = instance['IAMDatabaseAuthenticationEnabled']
add(results, iam_auth ? 'REVIEW' : 'PASS', '0-1-14 IAM DB 認証', iam_auth ? '有効。Green 用リソース ID の IAM ポリシー更新手順を確認' : '無効', 'db-instance.json')

stops = results.count { |status, *| status == 'STOP' }
reviews = results.count { |status, *| status == 'REVIEW' }
passes = results.count { |status, *| status == 'PASS' }

# 標準出力の書式は従来どおり（既存の手順・呼び出し側を壊さない）。
puts "Blue/Green 成立条件チェック: #{instance['DBInstanceIdentifier']}"
puts "収集日時: #{metadata['collected_at']} / 判定対象: #{metadata['target_engine_version']}"
puts format('%-8s %-30s %s', 'STATUS', 'ITEM', 'DETAIL')
puts '-' * 100
results.each { |status, item, detail, _source| puts format('%-8s %-30s %s', status, item, detail) }
puts "結果: STOP=#{stops}, REVIEW=#{reviews}"

# --- Markdown レポート ------------------------------------------------------
# ゲート①の判断材料として残す。判定だけでなく観測値と取得元も出す。
# 「なぜ移行可能と判断したか」「なぜこの対象を選んだか」を後から辿れるようにする。
def escape_cell(value)
  value.to_s.gsub('|', '\|').gsub("\n", ' ')
end

def render_report(instance, metadata, results, stops, reviews, passes)
  verdict = stops.zero? ? '**移行可能**（STOP なし）' : "**移行不可**（STOP #{stops} 件）"
  lines = []
  lines << '# Blue/Green 成立条件チェック'
  lines << ''
  lines << '| 項目 | 値 |'
  lines << '|---|---|'
  lines << "| 対象インスタンス | `#{escape_cell(instance['DBInstanceIdentifier'])}` |"
  lines << "| エンジン | #{escape_cell(instance['Engine'])} #{escape_cell(instance['EngineVersion'])} |"
  lines << "| インスタンスクラス | #{escape_cell(instance['DBInstanceClass'])} |"
  lines << "| 判定対象バージョン | #{escape_cell(metadata['target_engine_version'])} |"
  lines << "| 収集日時 | #{escape_cell(metadata['collected_at'])} |"
  lines << "| 判定 | #{verdict} |"
  lines << ''
  lines << "**PASS #{passes} 件 / REVIEW #{reviews} 件 / STOP #{stops} 件**"
  lines << ''
  lines << '## 判断材料と値'
  lines << ''
  lines << '判定の根拠になった観測値と、その値を読んだ収集ファイルを示す。'
  lines << ''
  lines << '| 判定 | 項目 | 観測値 | 取得元 |'
  lines << '|---|---|---|---|'
  results.each do |status, item, detail, source|
    lines << "| #{status} | #{escape_cell(item)} | #{escape_cell(detail)} | `#{escape_cell(source)}` |"
  end
  lines << ''

  unless stops.zero?
    lines << '## STOP — 解消しないと移行できない'
    lines << ''
    results.select { |status, *| status == 'STOP' }.each do |_status, item, detail, source|
      lines << "- **#{item}** … #{detail}（`#{source}`）"
    end
    lines << ''
  end

  unless reviews.zero?
    lines << '## REVIEW — 人の確認が要る'
    lines << ''
    results.select { |status, *| status == 'REVIEW' }.each do |_status, item, detail, source|
      lines << "- **#{item}** … #{detail}（`#{source}`）"
    end
    lines << ''
  end

  lines << '## この結果の読み方'
  lines << ''
  lines << '- **STOP が 1 件でも残る間は移行できない。**先に解消する'
  lines << '- **REVIEW は自動判定では決められない項目である。**人が確認して可否を決める'
  lines << '- このレポートは収集済み JSON だけから作る。**AWS へは接続していない**ため、'
  lines << '  収集時点（上記の収集日時）の状態を示す。時間が空いたら再収集する'
  lines << '- 項目の採番は `phase-0-precheck.md` のチェックリストに対応する'
  lines << ''
  lines << 'この結果をもとに、**移行できるか・どのインスタンスを対象にするか**を判断する。'
  lines << '対象を決めたら次は移行設定の生成とそのレビューへ進む（`report-generation-flows.md`）。'
  lines.join("\n") + "\n"
end

if options[:output]
  File.write(options[:output], render_report(instance, metadata, results, stops, reviews, passes))
  puts "Report: #{options[:output]}"
end

exit(stops.zero? ? 0 : 1)
