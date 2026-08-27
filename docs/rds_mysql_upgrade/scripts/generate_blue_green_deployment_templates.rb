#!/usr/bin/env ruby
# frozen_string_literal: true

# config/rds-blue-green-deployment-targets.yml から、サービスごとに 1 つの
# CloudFormation テンプレートを生成する。
#
# 入力は collect_blue_green_prereqs.sh が読み取り専用の AWS CLI 操作
# `aws rds describe-db-instances --output json` で収集した all-db-instances.json とする。
# このスクリプト自身は AWS CLI・AWS API を呼び出さず、収集済み JSON の判定と
# CloudFormation YAML／構築対象一覧の生成だけを Ruby で行う。

require 'json'
require 'yaml'
require 'optparse'
require 'fileutils'

options = {
  config: 'config/rds-blue-green-deployment-targets.yml',
  output_dir: 'generated/blue-green-deployments',
  services: []
}

OptionParser.new do |parser|
  parser.banner = <<~USAGE
    Usage: generate_blue_green_deployment_templates.rb --input-dir DIR [options]

    config の全 services を対象に CloudFormation YAML を生成する。
    --service を 1 回以上指定した場合は、指定サービスだけを生成する。
  USAGE
  parser.on('--input-dir DIR', 'collect_blue_green_prereqs.sh の JSON 出力ディレクトリ（必須）') { |value| options[:input_dir] = value }
  parser.on('--config FILE', 'Default: config/rds-blue-green-deployment-targets.yml') { |value| options[:config] = value }
  parser.on('--output-dir DIR', 'Default: generated/blue-green-deployments') { |value| options[:output_dir] = value }
  parser.on('--service NAME', '対象サービス。複数回指定可。未指定時は全サービス') { |value| options[:services] << value }
  parser.on('-h', '--help', 'このヘルプを表示する') { puts parser; exit }
end.parse!

def abort_with(message)
  warn "ERROR: #{message}"
  exit 1
end

def fetch_required(hash, key, context)
  value = hash[key]
  abort_with "#{context}: #{key} が未定義です。" if value.nil? || value.to_s.empty?
  value
end

def read_db_instances(input_dir)
  path = File.join(input_dir, 'all-db-instances.json')
  response = JSON.parse(File.read(path))
  instances = response.fetch('DBInstances')
  abort_with "#{path}: DBInstances が空です。" if instances.empty?

  instances.each_with_object({}) do |instance, result|
    identifier = instance['DBInstanceIdentifier']
    next if identifier.nil? || identifier.empty?

    result[identifier] = {
      'arn' => instance['DBInstanceArn'],
      'engine' => instance['Engine'],
      'engine_version' => instance['EngineVersion'],
      'db_instance_class' => instance['DBInstanceClass'],
      'db_parameter_group_names' => instance.fetch('DBParameterGroups', []).map { |group| group['DBParameterGroupName'] }.compact
    }
  end
rescue Errno::ENOENT
  abort_with "#{path} が見つかりません。collect_blue_green_prereqs.sh の出力を --input-dir に指定してください。"
rescue JSON::ParserError => e
  abort_with "#{path} の JSON を解析できませんでした: #{e.message}"
end

def find_in_map(environment, attribute)
  {
    'Fn::FindInMap' => [
      'DeploymentTarget',
      { 'Ref' => 'Environment' },
      attribute
    ]
  }
end

def build_template(service_name, environments)
  deployment_target = environments.transform_values do |target|
    {
      'SourceDBInstanceArn' => target.fetch('source_db_instance_arn'),
      'TargetDBInstanceClass' => target.fetch('target_db_instance_class'),
      'TargetParameterGroupExportName' => target.fetch('target_parameter_group_export_name')
    }
  end

  {
    'AWSTemplateFormatVersion' => '2010-09-09',
    'Description' => "#{service_name} の RDS for MySQL Blue/Green Deployment を作成する（自動生成）",
    'Metadata' => {
      'Documentation' => {
        'Purpose' => 'RDS CreateBlueGreenDeployment API をカスタムリソース経由で呼び出す。CloudFormation にネイティブ RDS Blue/Green Deployment リソースはない。',
        'EnvironmentSelection' => 'Environment パラメータで選択した環境の移行元 DB、Green DB インスタンスタイプ、MySQL 8.4 パラメータグループを Mappings から取得する。',
        'SourceDbArn' => 'SourceDBInstanceArn は事前収集した all-db-instances.json の describe-db-instances 結果から設定した値。',
        'Switchover' => 'switchover はこのスタックに含めない。承認済みの独立操作として実施する。'
      }
    },
    'Parameters' => {
      'Environment' => {
        'Type' => 'String',
        'Description' => 'デプロイ対象環境。Mappings に定義済みの環境を指定する。',
        'AllowedValues' => environments.keys.sort
      },
      'BlueGreenDeploymentProviderServiceToken' => {
        'Type' => 'String',
        'Description' => 'Custom::RdsBlueGreenDeployment プロバイダーの Lambda 関数等の ARN。'
      },
      'BlueGreenDeploymentName' => {
        'Type' => 'String',
        'Description' => 'RDS Blue/Green Deployment の一意な名前。',
        'AllowedPattern' => '^[a-zA-Z][a-zA-Z0-9-]{0,59}$'
      },
      'TargetEngineVersion' => {
        'Type' => 'String',
        'Description' => 'Green DB の目標 RDS for MySQL エンジンバージョン。対象リージョンでサポートされる 8.4 系を指定する。'
      }
    },
    'Mappings' => { 'DeploymentTarget' => deployment_target },
    'Resources' => {
      'RdsBlueGreenDeployment' => {
        'Type' => 'Custom::RdsBlueGreenDeployment',
        'DeletionPolicy' => 'Retain',
        'UpdateReplacePolicy' => 'Retain',
        'Properties' => {
          'ServiceToken' => { 'Ref' => 'BlueGreenDeploymentProviderServiceToken' },
          'BlueGreenDeploymentName' => { 'Ref' => 'BlueGreenDeploymentName' },
          'Source' => find_in_map(nil, 'SourceDBInstanceArn'),
          'TargetEngineVersion' => { 'Ref' => 'TargetEngineVersion' },
          'TargetDBInstanceClass' => find_in_map(nil, 'TargetDBInstanceClass'),
          'TargetDBParameterGroupName' => {
            'Fn::ImportValue' => find_in_map(nil, 'TargetParameterGroupExportName')
          }
        }
      }
    },
    'Outputs' => {
      'BlueGreenDeploymentIdentifier' => {
        'Description' => 'カスタムリソースプロバイダーが返す RDS Blue/Green Deployment 識別子。',
        'Value' => { 'Fn::GetAtt' => ['RdsBlueGreenDeployment', 'BlueGreenDeploymentIdentifier'] }
      },
      'GreenDBInstanceArn' => {
        'Description' => 'カスタムリソースプロバイダーが返す Green DB インスタンス ARN。',
        'Value' => { 'Fn::GetAtt' => ['RdsBlueGreenDeployment', 'GreenDBInstanceArn'] }
      }
    }
  }
end

def markdown_cell(value)
  (value || '取得なし').to_s.gsub('|', '\\|').gsub("\n", '<br>')
end

def write_deployment_plan(output_dir, plans)
  path = File.join(output_dir, 'blue-green-deployment-plan.md')
  File.open(path, 'w') do |file|
    file.puts '# RDS for MySQL Blue/Green 構築対象一覧'
    file.puts
    file.puts 'このファイルは `config/rds-blue-green-deployment-targets.yml` を基に、今回 CloudFormation YAML を生成したサービスの構築対象を一覧化したものである。'
    file.puts '移行元 DB の情報は、事前に読み取り専用の `aws rds describe-db-instances` で収集した `all-db-instances.json` の取得結果である。'
    file.puts
    file.puts '## 構築対象と設定'
    file.puts
    file.puts '| サービス | 環境 | 移行元 DB インスタンス | 移行元 ARN | 移行元エンジン | 移行元インスタンスタイプ | 移行元パラメータグループ | Green インスタンスタイプ | MySQL 8.4 パラメータグループ Export | 生成テンプレート |'
    file.puts '|---|---|---|---|---|---|---|---|---|---|'
    plans.sort_by { |plan| [plan['service'], plan['environment']] }.each do |plan|
      file.puts "| #{[plan['service'], plan['environment'], plan['source_db_instance_identifier'], plan['source_db_instance_arn'], plan['source_engine'], plan['source_db_instance_class'], plan['source_db_parameter_group_names'].join(', '), plan['target_db_instance_class'], plan['target_parameter_group_export_name'], plan['template_path']].map { |value| markdown_cell(value) }.join(' | ')} |"
    end
    file.puts
    file.puts '## 実行時に指定する値'
    file.puts
    file.puts '- `BlueGreenDeploymentProviderServiceToken`: `CreateBlueGreenDeployment` を実行するカスタムリソースプロバイダーの ARN。'
    file.puts '- `BlueGreenDeploymentName`: RDS 上で一意な Blue/Green Deployment 名。'
    file.puts '- `TargetEngineVersion`: 対象リージョンでサポートされる MySQL 8.4 の目標バージョン。'
    file.puts
    file.puts '## 留意事項'
    file.puts
    file.puts '- CloudFormation に RDS Blue/Green Deployment のネイティブリソースはないため、生成テンプレートはカスタムリソースを使用する。'
    file.puts '- switchover はこの生成対象に含めない。構築後の検証・承認を経た独立操作として実施する。'
  end
  path
end

begin
  config = YAML.load_file(options[:config])
rescue Errno::ENOENT
  abort_with "設定ファイルが見つかりません: #{options[:config]}"
rescue Psych::SyntaxError => e
  abort_with "設定ファイルの YAML 構文が不正です: #{e.message}"
end

abort_with '--input-dir is required.' unless options[:input_dir]
db_instances = read_db_instances(options[:input_dir])

services = fetch_required(config, 'services', options[:config])
abort_with "#{options[:config]}: services はマッピングで指定してください。" unless services.is_a?(Hash)
selected_names = options[:services].empty? ? services.keys.sort : options[:services].uniq
unknown_names = selected_names - services.keys
abort_with "未定義のサービスです: #{unknown_names.join(', ')}" unless unknown_names.empty?

FileUtils.mkdir_p(options[:output_dir])
plans = []
selected_names.each do |service_name|
  abort_with "サービス名に使用できない文字があります: #{service_name}" unless service_name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9-]*\z/)

  service = services.fetch(service_name)
  environments = fetch_required(service, 'environments', "services.#{service_name}")
  abort_with "services.#{service_name}.environments は空にできません。" unless environments.is_a?(Hash) && !environments.empty?

  resolved_environments = environments.each_with_object({}) do |(environment, target), result|
    context = "services.#{service_name}.environments.#{environment}"
    abort_with "#{context} はマッピングで指定してください。" unless target.is_a?(Hash)
    identifier = fetch_required(target, 'source_db_instance_identifier', context)
    source = db_instances[identifier]
    abort_with "#{context}: source_db_instance_identifier=#{identifier} が all-db-instances.json に存在しません。" unless source
    abort_with "#{context}: #{identifier} の DBInstanceArn が取得されていません。" if source['arn'].nil? || source['arn'].empty?
    result[environment] = {
      'source_db_instance_arn' => source.fetch('arn'),
      'target_db_instance_class' => fetch_required(target, 'target_db_instance_class', context),
      'target_parameter_group_export_name' => fetch_required(target, 'target_parameter_group_export_name', context)
    }
  end

  output_path = File.join(options[:output_dir], "#{service_name}-blue-green-deployment.yaml")
  File.write(output_path, YAML.dump(build_template(service_name, resolved_environments)).sub(/\A---\n/, ''))
  puts "Generated: #{output_path}"

  resolved_environments.each do |environment, target|
    source = db_instances.fetch(environments.fetch(environment).fetch('source_db_instance_identifier'))
    plans << {
      'service' => service_name,
      'environment' => environment,
      'source_db_instance_identifier' => environments.fetch(environment).fetch('source_db_instance_identifier'),
      'source_db_instance_arn' => source.fetch('arn'),
      'source_engine' => [source['engine'], source['engine_version']].compact.join(' '),
      'source_db_instance_class' => source['db_instance_class'],
      'source_db_parameter_group_names' => source['db_parameter_group_names'],
      'target_db_instance_class' => target.fetch('target_db_instance_class'),
      'target_parameter_group_export_name' => target.fetch('target_parameter_group_export_name'),
      'template_path' => output_path
    }
  end
end

plan_path = write_deployment_plan(options[:output_dir], plans)
puts "Generated: #{plan_path}"
