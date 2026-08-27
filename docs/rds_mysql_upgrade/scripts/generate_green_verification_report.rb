#!/usr/bin/env ruby
# frozen_string_literal: true
# Step 4 の収集済み JSON と Step 2 の CloudFormation YAML から、人が確認する
# Green 構成・パラメータ整合性レポートを生成する。AWS API は呼び出さない。
require 'json'
require 'yaml'
require 'optparse'

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: generate_green_verification_report.rb --template FILE --green-instance FILE --deployment FILE --user-parameters FILE --system-parameters FILE --all-parameters FILE --replica-lag FILE --output FILE'
  parser.on('--template FILE') { |value| options[:template] = value }
  parser.on('--green-instance FILE') { |value| options[:green_instance] = value }
  parser.on('--deployment FILE') { |value| options[:deployment] = value }
  parser.on('--user-parameters FILE') { |value| options[:user_parameters] = value }
  parser.on('--system-parameters FILE') { |value| options[:system_parameters] = value }
  parser.on('--all-parameters FILE') { |value| options[:all_parameters] = value }
  parser.on('--replica-lag FILE') { |value| options[:replica_lag] = value }
  parser.on('--runtime-values FILE', 'MySQL クライアントで収集した Green の実効値 JSON（任意）') { |value| options[:runtime_values] = value }
  parser.on('--output FILE') { |value| options[:output] = value }
  parser.on('-h', '--help') { puts parser; exit }
end.parse!
%i[template green_instance deployment user_parameters system_parameters all_parameters replica_lag output].each do |key|
  abort "--#{key.to_s.tr('_', '-')} is required." unless options[key]
end

template = YAML.load_file(options[:template])
resource = template.fetch('Resources').values.find { |item| item['Type'] == 'AWS::RDS::DBParameterGroup' }
abort "#{options[:template]}: AWS::RDS::DBParameterGroup が見つかりません。" unless resource
expected = resource.fetch('Properties').fetch('Parameters', {}).transform_values(&:to_s)

read_parameters = lambda do |path|
  JSON.parse(File.read(path)).fetch('Parameters').each_with_object({}) do |parameter, result|
    result[parameter['ParameterName']] = parameter
  end
end
user = read_parameters.call(options[:user_parameters])
system = read_parameters.call(options[:system_parameters])
all = read_parameters.call(options[:all_parameters])
runtime = if options[:runtime_values]
            JSON.parse(File.read(options[:runtime_values])).fetch('Parameters', {})
          else
            {}
          end
instance = JSON.parse(File.read(options[:green_instance])).fetch('DBInstances').first
deployment = JSON.parse(File.read(options[:deployment])).fetch('BlueGreenDeployments').first
lag_points = JSON.parse(File.read(options[:replica_lag])).fetch('Datapoints')

escape = ->(value) { (value || '').to_s.gsub('|', '\\|').gsub("\n", '<br>') }
parameter_names = (expected.keys + user.keys).uniq.sort

File.open(options[:output], 'w') do |file|
  file.puts '# Green 構成・パラメーター検証レポート'
  file.puts
  file.puts 'このレポートは、Step 2 の CloudFormation YAML、RDS DB パラメータグループの取得結果、および Green DB の関連付け状態を比較したものである。'
  file.puts
  file.puts '## 1. Blue/Green Deployment と Green DB の状態'
  file.puts
  file.puts "- Deployment: `#{deployment['BlueGreenDeploymentIdentifier']}` / `#{deployment['Status']}`"
  file.puts "- Green DB ARN: `#{deployment['Target']}`"
  file.puts "- Green engine: `#{instance['Engine']} #{instance['EngineVersion']}`"
  file.puts "- Green instance class: `#{instance['DBInstanceClass']}`"
  instance.fetch('DBParameterGroups', []).each do |group|
    file.puts "- Associated DB parameter group: `#{group['DBParameterGroupName']}` / apply status: `#{group['ParameterApplyStatus']}`"
  end
  file.puts
  file.puts '## 2. パラメーターグループ設定と YAML の一致'
  file.puts
  parameter_names = (parameter_names + runtime.keys).uniq.sort
  file.puts '| Parameter | CloudFormation YAML の宣言値 | RDS PG Source=user | 比較バリデーション | RDS PG Source=system | MySQL 実効値 | RDS PG が返す Source |'
  file.puts '|---|---|---|---|---|---|---|'
  parameter_names.each do |name|
    yaml_value = expected[name]
    user_value = user.dig(name, 'ParameterValue')
    system_value = system.dig(name, 'ParameterValue')
    rds_source = all.dig(name, 'Source')
    result = if yaml_value && user_value
               yaml_value == user_value.to_s ? '一致' : '不一致'
             elsif yaml_value
               'YAML のみ（RDS PG に未反映）'
             else
               'RDS PG のみ（YAML 外の user 定義）'
             end
    runtime_value = runtime[name]
    file.puts "| #{escape.call(name)} | #{escape.call(yaml_value)} | #{escape.call(user_value)} | #{result} | #{escape.call(system_value)} | #{escape.call(runtime_value || '未収集')} | #{escape.call(rds_source)} |"
  end
  file.puts
  file.puts '## 3. RDS が返す値の読み方'
  file.puts
  file.puts '- **RDS PG Source=user** は、カスタムパラメーターグループへ明示設定された値である。CloudFormation YAML との一致だけを比較バリデーションの対象とする。'
  file.puts '- **RDS PG Source=system** は、RDS が system 由来としてパラメーターグループ API で返した値である。インスタンスタイプ等により RDS が決める対象を確認する補助情報である。'
  file.puts '- **MySQL 実効値** は Green DB へ MySQL クライアントで接続し、`performance_schema.global_variables` から収集した値である。RDS の算出・上限調整を含みうるため、YAML／Source=user とは比較バリデーションしない。'
  file.puts
  file.puts '## 4. レプリカ同期'
  file.puts
  if lag_points.empty?
    file.puts '- ReplicaLag: データポイントなし（判定失敗）'
  else
    max_lag = lag_points.map { |point| point['Maximum'].to_f }.max
    file.puts "- ReplicaLag（直近 10 分・1 分粒度の最大値）: `#{max_lag}` 秒"
  end
  file.puts
  file.puts '## レポートの利用方法'
  file.puts
  file.puts '- YAML と RDS PG Source=user の差分は構成ドリフトとして扱う。MySQL 実効値・算出値の妥当性は、インスタンスサイズと負荷条件を踏まえて人が判断する。'
end

drift = parameter_names.select do |name|
  yaml_value = expected[name]
  user_value = user.dig(name, 'ParameterValue')
  (yaml_value && user_value && yaml_value != user_value.to_s) || (yaml_value && !user_value) || (!yaml_value && user_value)
end
warn "CloudFormation YAML と RDS PG Source=user の不一致: #{drift.join(', ')}" unless drift.empty?
exit(drift.empty? ? 0 : 1)
