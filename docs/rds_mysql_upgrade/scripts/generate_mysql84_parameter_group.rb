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

def yaml_scalar(value)
  '"' + value.to_s.gsub('\\', '\\\\').gsub('"', '\\"') + '"'
end

input = options[:input_dir]
metadata = read_json(input, 'metadata.json')
source_group = read_json(input, 'source-parameter-group.json').fetch('DBParameterGroups').first
source_user = read_json(input, 'source-user-parameters.json').fetch('Parameters')
defaults80 = read_json(input, 'mysql80-default-parameters.json').fetch('EngineDefaults').fetch('Parameters')
defaults84 = read_json(input, 'mysql84-default-parameters.json').fetch('EngineDefaults').fetch('Parameters')
rules = YAML.load_file(options[:rules]).fetch('rules', {})
default80_by_name = defaults80.to_h { |item| [item['ParameterName'], item] }
default84_by_name = defaults84.to_h { |item| [item['ParameterName'], item] }

rows = []
generated = {}
source_user.each do |parameter|
  name = parameter.fetch('ParameterName')
  value = parameter['ParameterValue']
  rule = rules[name] || { 'action' => 'review', 'rationale' => '移行ルール未登録' }
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
    result = 'REVIEW'
  else
    result = 'BLOCKED'
    detail = "未知の action: #{action}"
  end

  rows << { name: name, source_value: value, default80: default80_by_name.dig(name, 'ParameterValue'), target: target,
            default84: target_parameter && target_parameter['ParameterValue'], allowed84: target_parameter && target_parameter['AllowedValues'],
            apply_type84: target_parameter && target_parameter['ApplyType'], action: action, result: result, detail: detail }
end

# Source=user に存在しない必須設定も force ルールなら追加する。
rules.each do |name, rule|
  next unless rule['action'] == 'force' && !generated.key?(rule['target'] || name)
  target = rule['target'] || name
  parameter = default84_by_name[target]
  if parameter && parameter['IsModifiable']
    generated[target] = rule.fetch('value')
    rows << { name: name, source_value: '(未設定)', default80: default80_by_name.dig(name, 'ParameterValue'), target: target,
              default84: parameter['ParameterValue'], allowed84: parameter['AllowedValues'], apply_type84: parameter['ApplyType'],
              action: 'force', result: 'GENERATED', detail: rule['rationale'] || '' }
  else
    rows << { name: name, source_value: '(未設定)', default80: nil, target: target, default84: nil, allowed84: nil, apply_type84: nil,
              action: 'force', result: 'BLOCKED', detail: "#{rule['rationale']} / 8.4 に存在しない、または変更不可" }
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
File.open(template_path, 'w') do |file|
  file.puts "AWSTemplateFormatVersion: '2010-09-09'"
  file.puts 'Description: MySQL 8.4 DB parameter group only (generated; review before deployment)'
  file.puts 'Resources:'
  file.puts '  Mysql84ParameterGroup:'
  file.puts '    Type: AWS::RDS::DBParameterGroup'
  file.puts '    Properties:'
  file.puts "      DBParameterGroupName: #{yaml_scalar(name)}"
  file.puts "      Description: #{yaml_scalar("MySQL 8.4 parameters for #{options[:system]}/#{options[:environment]}")}"
  file.puts '      Family: mysql8.4'
  file.puts '      Parameters:'
  generated.sort.each { |key, value| file.puts "        #{key}: #{yaml_scalar(value)}" }
  file.puts '      Tags:'
  file.puts "        - Key: System\n          Value: #{yaml_scalar(options[:system])}"
  file.puts "        - Key: Environment\n          Value: #{yaml_scalar(options[:environment])}"
  file.puts '        - Key: ManagedBy\n          Value: CloudFormation'
  file.puts 'Outputs:'
  file.puts '  DBParameterGroupName:'
  file.puts '    Value: !Ref Mysql84ParameterGroup'
end

report_path = File.join(options[:output_dir], 'mysql80-to-mysql84-parameter-report.md')
File.open(report_path, 'w') do |file|
  file.puts '# MySQL 8.0 → 8.4 パラメータ移行レポート'
  file.puts
  file.puts "- Source parameter group: `#{source_group['DBParameterGroupName']}` (`#{source_group['DBParameterGroupFamily']}`)"
  file.puts "- Source group apply status: `#{instance_status}`"
  file.puts "- Collected at: `#{metadata['collected_at']}`"
  file.puts "- Rules: `#{options[:rules]}`"
  file.puts "- Generated parameters: `#{generated.length}`"
  file.puts
  file.puts '| Source parameter | 8.0 user value | 8.0 default | 8.4 target | 8.4 default | 8.4 allowed / apply | Rule | Result | Note |'
  file.puts '|---|---|---|---|---|---|---|---|---|'
  rows.sort_by { |row| row[:name] }.each do |row|
    target_info = [row[:allowed84], row[:apply_type84]].compact.join(' / ')
    values = [row[:name], row[:source_value], row[:default80], row[:target], row[:default84], target_info, row[:action], row[:result], row[:detail]]
    file.puts '| ' + values.map { |value| (value || '').to_s.gsub('|', '\\|') }.join(' | ') + ' |'
  end
  file.puts
  file.puts '## 判定'
  file.puts
  file.puts "- BLOCKED: #{rows.count { |row| row[:result] == 'BLOCKED' }}"
  file.puts "- REVIEW: #{rows.count { |row| row[:result] == 'REVIEW' }}"
  file.puts 'REVIEW または BLOCKED が残る場合、生成 YAML をデプロイしない。ルールを更新して再生成する。'
end

blocked = rows.count { |row| row[:result] == 'BLOCKED' }
review = rows.count { |row| row[:result] == 'REVIEW' }
puts "Generated: #{template_path}"
puts "Report: #{report_path}"
puts "Result: GENERATED=#{generated.length}, REVIEW=#{review}, BLOCKED=#{blocked}"
exit((blocked.zero? && review.zero?) ? 0 : 1)
