#!/usr/bin/env ruby
# frozen_string_literal: true
# AWS API は呼ばず、収集済み JSON と移行ルールから CloudFormation YAML とレビュー報告を生成する。
require 'json'
require 'yaml'
require 'optparse'
require 'fileutils'

options = { rules: 'config/mysql80-to-84-parameter-rules.yml' }
OptionParser.new do |parser|
  parser.banner = 'Usage: generate_mysql84_parameter_group.rb --input-dir DIR --output-dir DIR --system NAME --environment NAME [options]'
  parser.on('--input-dir DIR') { |value| options[:input_dir] = value }
  parser.on('--output-dir DIR') { |value| options[:output_dir] = value }
  parser.on('--system NAME') { |value| options[:system] = value }
  parser.on('--environment NAME') { |value| options[:environment] = value }
  parser.on('--rules FILE', 'Default: config/mysql80-to-84-parameter-rules.yml') { |value| options[:rules] = value }
  parser.on('-h', '--help') { puts parser; exit }
end.parse!
%i[input_dir output_dir system environment].each { |key| abort "--#{key.to_s.tr('_', '-')} is required." unless options[key] }

def read_json(dir, name)
  JSON.parse(File.read(File.join(dir, name)))
rescue Errno::ENOENT
  abort "Missing #{name}; run collect_mysql84_parameter_inputs.sh first."
end

input = options[:input_dir]
metadata = read_json(input, 'metadata.json')
source_group = read_json(input, 'source-parameter-group.json').fetch('DBParameterGroups').first
source_user = read_json(input, 'source-user-parameters.json').fetch('Parameters')
source_system_path = File.join(input, 'source-system-parameters.json')
source_system_collected = File.exist?(source_system_path)
source_system = if source_system_collected
                  read_json(input, 'source-system-parameters.json').fetch('Parameters')
                else
                  []
                end
defaults80 = read_json(input, 'mysql80-default-parameters.json').fetch('EngineDefaults').fetch('Parameters')
defaults84 = read_json(input, 'mysql84-default-parameters.json').fetch('EngineDefaults').fetch('Parameters')
rules = YAML.load_file(options[:rules]).fetch('rules', {})
default80_by_name = defaults80.to_h { |item| [item['ParameterName'], item] }
default84_by_name = defaults84.to_h { |item| [item['ParameterName'], item] }
system80_by_name = source_system.to_h { |item| [item['ParameterName'], item] }
system80_value = lambda do |parameter_name|
  system80_by_name.dig(parameter_name, 'ParameterValue') || (source_system_collected ? 'なし' : '未収集')
end
source_parameter_names = source_user.map { |parameter| parameter['ParameterName'] }

rows = []
generated = {}
source_user.each do |parameter|
  name = parameter.fetch('ParameterName')
  value = parameter['ParameterValue']
  # Source=user は、保留・廃止と明示したルールを除き、8.4 に存在し変更可能であれば YAML へ反映する。
  rule = rules[name] || { 'action' => 'copy', 'rationale' => '移行ルール未登録。Source=user の値を同名で反映する' }
  action = rule.fetch('action', 'review')
  target = rule['target'] || name
  target_parameter = default84_by_name[target]
  result = 'REVIEW'
  detail = rule['rationale'] || ''

  case action
  when 'copy'
    if target_parameter && target_parameter['IsModifiable']
      generated[target] = value
      result = 'GENERATED'
    else
      result = 'BLOCKED'
      detail = "#{detail} / 8.4 に存在しない、または変更不可"
    end
  when 'force'
    if target_parameter && target_parameter['IsModifiable']
      generated[target] = rule.fetch('value')
      result = 'GENERATED'
    else
      result = 'BLOCKED'
      detail = "#{detail} / 8.4 に存在しない、または変更不可"
    end
  when 'omit'
    result = 'OMITTED'
  when 'review'
    if target_parameter && target_parameter['IsModifiable']
      generated[target] = value
      result = 'GENERATED'
      detail = "#{detail} / Source=user の値を明示設定として反映する"
    else
      result = 'BLOCKED'
      detail = "#{detail} / 8.4 に存在しない、または変更不可"
    end
  else
    result = 'BLOCKED'
    detail = "未知の action: #{action}"
  end

  rows << { name: name, source_value: value, engine_default80: default80_by_name.dig(name, 'ParameterValue'), system80: system80_by_name.dig(name, 'ParameterValue'), target: target,
            default84: target_parameter && target_parameter['ParameterValue'], allowed84: target_parameter && target_parameter['AllowedValues'],
            apply_type84: target_parameter && target_parameter['ApplyType'], action: action, result: result, detail: detail }
end

# Source=user に存在しない force ルールと、target_only の新規 8.4 パラメータを処理する。
rules.each do |name, rule|
  next if source_parameter_names.include?(name)
  target = rule['target'] || name
  parameter = default84_by_name[target]
  case rule['action']
  when 'force'
    next if rule['source_required']
    next if generated.key?(target)
    if parameter && parameter['IsModifiable']
      generated[target] = rule.fetch('value')
      rows << { name: name, source_value: '(未設定)', engine_default80: default80_by_name.dig(name, 'ParameterValue'), system80: system80_by_name.dig(name, 'ParameterValue'), target: target,
                default84: parameter['ParameterValue'], allowed84: parameter['AllowedValues'], apply_type84: parameter['ApplyType'],
                action: 'force', result: 'GENERATED', detail: rule['rationale'] || '' }
    else
      rows << { name: name, source_value: '(未設定)', engine_default80: nil, system80: nil, target: target, default84: nil, allowed84: nil, apply_type84: nil,
                action: 'force', result: 'BLOCKED', detail: "#{rule['rationale']} / 8.4 に存在しない、または変更不可" }
    end
  when 'review', 'omit'
    next unless rule['target_only']
    # 8.0 の user 定義から同じ 8.4 パラメータを生成済みなら、
    # 「8.4 新規・既定値を採用」の行は重複するため出力しない。
    next if generated.key?(target)
    rows << { name: name, source_value: '(8.4 新規)', engine_default80: nil, system80: nil, target: target,
              default84: parameter && parameter['ParameterValue'], allowed84: parameter && parameter['AllowedValues'], apply_type84: parameter && parameter['ApplyType'],
              action: rule['action'], result: rule['action'] == 'review' ? 'REVIEW' : 'OMITTED', detail: rule['rationale'] || '' }
  end
end

instance_status = if File.exist?(File.join(input, 'source-db-instance.json'))
                    instance = read_json(input, 'source-db-instance.json').fetch('DBInstances').first
                    group = instance.fetch('DBParameterGroups', []).find { |entry| entry['DBParameterGroupName'] == source_group['DBParameterGroupName'] }
                    group ? group['ParameterApplyStatus'] : '対象グループは関連付けられていない'
                  else
                    '未収集（--db-instance-id を指定して再収集可能）'
                  end

FileUtils.mkdir_p(options[:output_dir])
name = "#{options[:system]}-#{options[:environment]}-mysql84-v1".downcase
template_path = File.join(options[:output_dir], 'mysql84-parameter-group.yaml')
template = {
  'AWSTemplateFormatVersion' => '2010-09-09',
  'Description' => 'MySQL 8.4 DB parameter group only (generated; review before deployment)',
  'Resources' => {
    'Mysql84ParameterGroup' => {
      'Type' => 'AWS::RDS::DBParameterGroup',
      'Properties' => {
        'DBParameterGroupName' => name,
        'Description' => "MySQL 8.4 parameters for #{options[:system]}/#{options[:environment]}",
        'Family' => 'mysql8.4',
        'Parameters' => generated.sort.to_h,
        'Tags' => [
          { 'Key' => 'System', 'Value' => options[:system] },
          { 'Key' => 'Environment', 'Value' => options[:environment] },
          { 'Key' => 'ManagedBy', 'Value' => 'CloudFormation' }
        ]
      }
    }
  },
  'Outputs' => {
    'DBParameterGroupName' => {
      # !Ref と等価な CloudFormation の長形式。Ruby YAML モジュールで安全に出力する。
      'Value' => { 'Ref' => 'Mysql84ParameterGroup' }
    }
  }
}
File.write(template_path, YAML.dump(template).sub(/\A---\n/, ''))

report_path = File.join(options[:output_dir], 'mysql80-to-mysql84-parameter-report.md')
File.open(report_path, 'w') do |file|
  markdown_value = lambda { |value| (value || '').to_s.gsub('|', '\\|').gsub("\n", '<br>') }
  write_table_row = lambda do |values|
    file.puts '| ' + values.map { |value| markdown_value.call(value) }.join(' | ') + ' |'
  end
  result_label = {
    'GENERATED' => '生成済み',
    'OMITTED' => '設定対象外',
    'REVIEW' => '要レビュー',
    'BLOCKED' => '生成不可'
  }

  file.puts '# MySQL 8.0 → 8.4 パラメータ移行レポート'
  file.puts
  file.puts "- Source parameter group: `#{source_group['DBParameterGroupName']}` (`#{source_group['DBParameterGroupFamily']}`)"
  file.puts "- Source group apply status: `#{instance_status}`"
  file.puts "- Collected at: `#{metadata['collected_at']}`"
  file.puts "- Rules: `#{options[:rules]}`"
  file.puts "- Generated parameters: `#{generated.length}`"
  file.puts
  file.puts '## 値の由来'
  file.puts
  file.puts '- **8.0 engine default**: `describe-engine-default-parameters --db-parameter-group-family mysql8.0` が返すファミリーの既定値。`Source=system` の実効値ではない。'
  file.puts '- **8.0 Source=system**: `describe-db-parameters --source system` が現行カスタムグループについて返す、値の由来が RDS system であるパラメータ。該当値がない場合は `なし`、旧形式の入力で未収集の場合は `未収集` と表示する。'
  file.puts '- **8.0 Source=user**: `describe-db-parameters --source user` が返す明示設定値。'
  file.puts '- **8.4 engine default**: `describe-engine-default-parameters --db-parameter-group-family mysql8.4` が返すファミリーの既定値。Phase 1 では 8.4 DB に未関連付けのため、8.4 の `Source=system` は未取得・未確定である。'
  file.puts

  file.puts '## 1. 元の user 定義値'
  file.puts
  file.puts '`describe-db-parameters --source user` で取得した、8.0 カスタムパラメータグループの明示設定値である。'
  file.puts
  file.puts '| Parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | engine default との差分 |'
  file.puts '|---|---|---|---|---|'
  source_user.sort_by { |parameter| parameter['ParameterName'] }.each do |parameter|
    default_value = default80_by_name.dig(parameter['ParameterName'], 'ParameterValue')
    system_value = system80_value.call(parameter['ParameterName'])
    difference = parameter['ParameterValue'].to_s == default_value.to_s ? 'engine default と同一' : 'engine default から上書き'
    write_table_row.call([parameter['ParameterName'], parameter['ParameterValue'], default_value, system_value, difference])
  end
  file.puts '| (なし) |  |  |  |  |' if source_user.empty?
  file.puts

  file.puts '## 2. リネーム以外の値変更・新規追加パラメーター'
  file.puts
  file.puts '名称変更（旧名から新名への `copy`）を除き、移行ルールに定義した値・仕様変更候補と MySQL 8.4 新規パラメーターを一覧化する。8.0 側で user 定義がない項目は、8.4 の既定値を採用するかをレビューする。'
  file.puts
  file.puts '| 区分 | 8.0 parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | 8.4 parameter | 8.4 engine default | Rule | 処理結果 | 判断理由（8.0 時点を含む） |'
  file.puts '|---|---|---|---|---|---|---|---|---|---|'
  non_rename_rules = rules.select do |rule_name, rule|
    target = rule['target'] || rule_name
    rule['target_only'] || target == rule_name
  end
  non_rename_rules.sort.each do |rule_name, rule|
    target = rule['target'] || rule_name
    next if rule['target_only'] && generated.key?(target)
    row = rows.find { |candidate| candidate[:name] == rule_name }
    target_parameter = default84_by_name[target]
    category = if rule['target_only']
                 '8.4 新規'
               elsif rule['action'] == 'omit'
                 '廃止・代替'
               else
                 rule['report_category'] || '値・仕様変更候補'
               end
    result = row ? result_label.fetch(row[:result]) : '8.0 user 定義なし'
    source_default = default80_by_name.dig(rule_name, 'ParameterValue')
    source_system_value = system80_value.call(rule_name)
    source_context = if rule['target_only']
                       '8.0: パラメーターなし（8.4 新規）'
                     elsif row
                       if row[:source_value].to_s == source_default.to_s
                         "8.0: Source=user=#{row[:source_value]}（engine default と同一、Source=system=#{source_system_value}）"
                       else
                         "8.0: Source=user=#{row[:source_value]}（engine default=#{source_default || '取得なし'}、Source=system=#{source_system_value}）"
                       end
                     else
                       "8.0: Source=user なし（engine default=#{source_default || '取得なし'}、Source=system=#{source_system_value}）"
                     end
    rationale = [rule['rationale'], source_context].compact.join(' / ')
    write_table_row.call([category, rule_name, row && row[:source_value], source_default, source_system_value,
                          target, target_parameter && target_parameter['ParameterValue'], rule['action'], result, rationale])
  end
  file.puts

  file.puts '## 3. 移行処理結果'
  file.puts
  file.puts '収集された user 定義と `target_only` ルールを、生成可否まで含めて記録する。未登録の user 定義は、8.4 に同名で存在し変更可能なら同じ値を生成し、それ以外は「生成不可」として検出する。'
  file.puts
  file.puts '| Source parameter | 8.0 Source=user | 8.0 engine default | 8.0 Source=system | 8.4 target | 8.4 engine default | 8.4 allowed / apply | Rule | 処理結果 | 判断理由 |'
  file.puts '|---|---|---|---|---|---|---|---|---|---|'
  rows.sort_by { |row| row[:name] }.each do |row|
    target_info = [row[:allowed84], row[:apply_type84]].compact.join(' / ')
    values = [row[:name], row[:source_value], row[:engine_default80], system80_value.call(row[:name]), row[:target], row[:default84], target_info, row[:action], result_label.fetch(row[:result]), row[:detail]]
    write_table_row.call(values)
  end
  file.puts
  file.puts '## 判定'
  file.puts
  file.puts "- 生成不可: #{rows.count { |row| row[:result] == 'BLOCKED' }}"
  file.puts "- 要レビュー: #{rows.count { |row| row[:result] == 'REVIEW' }}"
  file.puts '「要レビュー」または「生成不可」が残る場合、生成 YAML をデプロイしない。ルールを更新して再生成する。'
end

blocked = rows.count { |row| row[:result] == 'BLOCKED' }
review = rows.count { |row| row[:result] == 'REVIEW' }
puts "Generated: #{template_path}"
puts "Report: #{report_path}"
puts "結果: 生成済み=#{generated.length}, 要レビュー=#{review}, 生成不可=#{blocked}"
exit((blocked.zero? && review.zero?) ? 0 : 1)
