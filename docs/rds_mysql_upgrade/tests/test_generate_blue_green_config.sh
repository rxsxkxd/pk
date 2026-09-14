#!/usr/bin/env bash
# Blue/Green 設定生成支援ツールのテスト。
# 実 AWS には接続せず、examples/ の describe-db-instances ダミー応答を使う。
# 出力はすべて一時ディレクトリに限定し、config/blue-green/{staging,production}.deployment.yml を変更しない。
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
fixture_dir="$repo_root/examples/config-blue-green-generation"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rds-config-generator-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/bin" "$work_dir/output"

# AWS CLI のダミー。収集器が組み立てる引数を 1 行ずつ記録し、
# describe-db-instances と describe-db-parameters を fixture から返し分ける。
# 読み取り API 以外を呼んだ場合は失敗させる。
cat > "$work_dir/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$AWS_MOCK_ARGUMENTS"
group=''
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == --db-parameter-group-name ]]; then
    next=$((i + 1)); group=${!next}
  fi
done
case " $* " in
  *' describe-db-instances '*)
    cat "$AWS_MOCK_INSTANCES" ;;
  *' describe-db-parameters '*)
    cat "$AWS_MOCK_PARAMETERS_DIR/${group}.json" ;;
  *)
    echo "unexpected AWS CLI call: $*" >&2; exit 64 ;;
esac
MOCK
chmod +x "$work_dir/bin/aws"

AWS_MOCK_ARGUMENTS="$work_dir/aws-arguments.txt" \
AWS_MOCK_INSTANCES="$fixture_dir/rds-instance-inventory.test.json" \
AWS_MOCK_PARAMETERS_DIR="$fixture_dir/describe-db-parameters" \
PATH="$work_dir/bin:$PATH" \
go -C "$repo_root" run ./scripts/collect_rds_instance_inventory \
  --region ap-northeast-1 \
  --profile test-readonly \
  --output "$work_dir/rds-instance-inventory.json"

# 読み取り API だけを、パラメータグループごとに 1 回ずつ呼んでいること。
ruby -rjson - "$work_dir/aws-arguments.txt" "$fixture_dir/rds-instance-inventory.test.json" <<'RB'
calls = File.readlines(ARGV[0]).map(&:strip).reject(&:empty?)
response = JSON.parse(File.read(ARGV[1]))
prefix = '--region ap-northeast-1 --profile test-readonly rds '

raise "unexpected first call: #{calls[0]}" unless
  calls[0] == prefix + 'describe-db-instances --output json'

groups = response['DBInstances']
           .flat_map { |instance| instance['DBParameterGroups'] }
           .map { |group| group['DBParameterGroupName'] }
           .uniq.sort
expected = groups
             .map { |name| "#{prefix}describe-db-parameters --db-parameter-group-name #{name} --output json" }
             .sort

raise "unexpected calls: #{calls[1..].inspect}" unless calls[1..].sort == expected
raise 'each parameter group must be read exactly once' unless calls[1..].length == groups.length
RB
ruby -rjson - "$fixture_dir/rds-instance-inventory.test.json" "$work_dir/rds-instance-inventory.json" <<'RB'
expected_response = JSON.parse(File.read(ARGV[0]))
inventory = JSON.parse(File.read(ARGV[1]))

raise 'aws_region mismatch' unless inventory['aws_region'] == 'ap-northeast-1'
raise 'DBInstances must be kept as collected' unless
  inventory['DBInstances'] == expected_response['DBInstances']

# パラメータグループごとに、採取対象パラメータの実値が入っていること。
groups = expected_response['DBInstances']
           .flat_map { |instance| instance['DBParameterGroups'] }
           .map { |group| group['DBParameterGroupName'] }
           .uniq.sort
raise "ParameterGroups mismatch: #{inventory['ParameterGroups'].keys.inspect}" unless
  inventory['ParameterGroups'].keys.sort == groups

inventory['ParameterGroups'].each do |name, facts|
  raise "#{name}: unexpected keys #{facts.keys.inspect}" unless facts.keys == ['Parameters']
  raise "#{name}: time_zone is missing" unless facts['Parameters'].key?('time_zone')
  facts['Parameters'].each do |parameter, value|
    raise "#{name}.#{parameter}: unexpected keys" unless value.keys.sort == %w[Source Value]
    raise "#{name}.#{parameter}: empty value" if value['Value'].to_s.empty? || value['Source'].to_s.empty?
  end
end
RB

for environment in development staging production; do
  # go.mod はリポジトリ直下にある。ここでは呼び出し元の cwd に依存しないよう
  # -C でリポジトリ直下を指定し、入出力は絶対パスで渡す。
  go -C "$repo_root" run ./scripts/generate_blue_green_config \
    --catalog "$fixture_dir/migration-catalog.test.yml" \
    --inventory "$work_dir/rds-instance-inventory.json" \
    --environment "$environment" \
    --output "$work_dir/output/$environment.yml"

  # レポートは YAML 生成とは別コマンドである。同じ入力から Markdown を組み立てる。
  go -C "$repo_root" run ./scripts/generate_blue_green_config_report \
    --catalog "$fixture_dir/migration-catalog.test.yml" \
    --inventory "$work_dir/rds-instance-inventory.json" \
    --environment "$environment" \
    --output "$work_dir/output/$environment.report.md"
  diff -u "$fixture_dir/blue-green.$environment.report.expected.md" \
    "$work_dir/output/$environment.report.md" || {
    echo "generated report differs from the expected test result: $environment" >&2
    exit 1
  }

  ruby -ryaml -rjson - "$work_dir/output/$environment.yml" \
    "$fixture_dir/blue-green.$environment.expected.yml" \
    "$fixture_dir/migration-catalog.test.yml" \
    "$environment" \
    "$work_dir/rds-instance-inventory.json" <<'RB'
actual = YAML.safe_load(File.read(ARGV[0]))
expected = YAML.safe_load(File.read(ARGV[1]))
catalog = YAML.safe_load(File.read(ARGV[2]))
environment = ARGV[3]
inventory_facts = JSON.parse(File.read(ARGV[4]))['ParameterGroups']

raise 'generated YAML differs from the expected test result' unless actual == expected

# カタログが新構造であること、および生成の要点を確認する。
applications = catalog['applications']
raise 'test fixture must contain multiple applications' unless applications.length >= 2
raise "unknown environment: #{environment}" unless catalog['database_environments'].include?(environment)

# その環境の接続を集め、生成単位（インスタンス）へ正しくまとめられたかを見る。
bindings = applications.flat_map do |_name, application|
  application['connections'].flat_map do |_connection_name, connection|
    (connection['environments'] || {}).filter_map do |env, binding|
      binding if env == environment
    end
  end
end
raise "test fixture has no connection for #{environment}" if bindings.empty?

instances = bindings.map { |binding| binding['rds_instance'] }.uniq.sort
raise 'services keys must be the RDS instances' unless actual['services'].keys.sort == instances

# 同じインスタンスを指す接続は 1 エントリへまとめ、schemas を集約する。
instances.each do |instance|
  service = actual['services'][instance]
  same = bindings.select { |binding| binding['rds_instance'] == instance }
  expected_schemas = same.map { |binding| binding['schema_name'] }.uniq.sort
  raise "#{instance}: schemas mismatch" unless service['schemas'] == expected_schemas
  # target を省略した接続は、共通ターゲットと Blue の実値で補完される。
  raise "#{instance}: target_engine_version is empty" if service['target_engine_version'].to_s.empty?
  raise "#{instance}: target_db_instance_class is empty" if service['target_db_instance_class'].to_s.empty?
  # 確認用のパラメータ実値は、Blue のパラメータグループの収集値をそのまま載せる。
  facts = inventory_facts[service['source_db_parameter_group_name']]['Parameters']
  wanted = facts.to_h { |name, value| [name, { 'value' => value['Value'], 'source' => value['Source'] }] }
  raise "#{instance}: source_db_parameters mismatch" unless service['source_db_parameters'] == wanted
end

# mysql_verification は、ルートの既定値を接続配下がキー単位で上書きする。
# auth_method は parameter_store 固定で、user はカタログに置かない。
defaults = catalog['mysql_verification'] || {}
instances.each do |instance|
  verification = actual['services'][instance]['mysql_verification']
  raise "#{instance}: auth_method must be parameter_store" unless
    verification['auth_method'] == 'parameter_store'
  # user はカタログに書けないため、生成結果にもキー自体が現れない。
  raise "#{instance}: user must not appear" if verification.key?('user')

  merged = defaults.dup
  bindings.select { |binding| binding['rds_instance'] == instance }.each do |binding|
    merged.merge!(binding['mysql_verification'] || {})
  end
  %w[enabled parameter_name user_parameter_name port].each do |key|
    next unless merged.key?(key)
    raise "#{instance}.#{key}: expected #{merged[key].inspect}, got #{verification[key].inspect}" unless
      verification[key] == merged[key]
  end
  next unless merged['enabled']
  raise "#{instance}: parameter_name is required" if verification['parameter_name'].to_s.empty?
  raise "#{instance}: user_parameter_name is required" if verification['user_parameter_name'].to_s.empty?
end

puts "Blue/Green config generator #{environment}: OK " \
     "(#{bindings.length} connections -> #{instances.length} deployments)"
RB
done
