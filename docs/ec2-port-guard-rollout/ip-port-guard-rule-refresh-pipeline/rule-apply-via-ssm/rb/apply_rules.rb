# frozen_string_literal: true

# インスタンスの一覧ファイルの台に、SSM の Run Command（AWS-RunShellScript）でルールの適用スクリプト（remote/apply-rules.sh）を流す。
# ルールのデプロイ先から照合の値と ipset 入れ替えスクリプトを取り、照合してから ipset を入れ替える。
# 1 台ずつ流し（--max-concurrency 1）、1 台でも失敗したら残りは流さない（--max-errors 0）。
#
#   ruby rb/apply_rules.rb --env staging [--list FILE] [--ipv6] [--s3-uri URI] [--profile NAME] [--region NAME]
#
# 終了コード: 0 全台が Success / 1 失敗した台がある / 2 使い方・前提の誤り・確かめて止めた / 3 AWS のエラー
require_relative 'lib/cli'

TERMINAL = %w[Success Cancelled TimedOut Failed].freeze
POLL_SECONDS = 5
PROGRESS_SECONDS = 30
REMOTE_SCRIPT = File.join(Cli::BASE_DIR, 'remote', 'apply-rules.sh')

options = Cli.parse_options do |parser, opts|
  parser.banner = 'usage: ruby rb/apply_rules.rb --env <環境> [options]'
  parser.on('--env NAME', Cli::ENVIRONMENTS, "環境（#{Cli::ENVIRONMENTS.join('・')}）") { |value| opts[:env] = value }
  parser.on('--list FILE', 'インスタンスの一覧ファイル（既定 instance-lists/<環境>.tsv）') { |value| opts[:list] = value }
  parser.on('--ipv6', 'refresh-ipv6.sh も流す（IPv6 も絞っている台）') { opts[:ipv6] = true }
  parser.on('--s3-uri URI', 'ルールのデプロイ先（既定は名前の決まりから組み立てる。末尾の / なし）') { |value| opts[:s3_uri] = value }
end
Cli.usage_error('--env を指定する') unless options[:env]
Cli.require_aws_cli
list_path = options[:list] || Cli.default_list_path(options[:env])
Cli.usage_error("インスタンスの一覧ファイルがない: #{list_path}（list_instances.rb で作る）") unless File.exist?(list_path)

# 1. インスタンスの一覧ファイルを読む（# から始まる行と空の行は無視。1 列目がインスタンス ID）
rows = File.readlines(list_path, chomp: true).reject { |line| line.strip.empty? || line.start_with?('#') }.map { |line| line.split("\t") }
invalid = rows.reject { |row| Cli::ID_PATTERN.match?(row[0].to_s) }
Cli.usage_error("インスタンス ID の形式が正しくない行がある: #{invalid.map(&:first).join(', ')}") unless invalid.empty?
Cli.usage_error("インスタンスの一覧ファイルに台がない: #{list_path}") if rows.empty?
Cli.usage_error('1 回に流せるのは 50 台まで（一覧ファイルを分ける）') if rows.size > 50
ids = rows.map(&:first).uniq

begin
  # 2. ルールのデプロイ先（親フォルダの command/set-s3-uri.sh と同じ組み立て方）
  region = AwsCli.region or Cli.usage_error('リージョンが決まらない（--region か AWS_REGION で指定する）')
  s3_uri = options[:s3_uri] || begin
    account_id = AwsCli.run('sts', 'get-caller-identity')['Account']
    "s3://ip-port-guard-rules-#{account_id}-#{region}-an/port-guard/#{options[:env]}/current"
  end

  # 3. 対象と取得元を表示して確かめる
  puts "環境: #{options[:env]}"
  puts "取得元（ルールのデプロイ先）: #{s3_uri}"
  puts "流す ipset 入れ替えスクリプト: refresh-ipv4.sh#{options[:ipv6] ? '・refresh-ipv6.sh' : ''}"
  puts "対象（#{ids.size} 台。1 台ずつ流し、1 台でも失敗したら残りは流さない）:"
  rows.each { |row| puts "  #{row.join("\t")}" }
  answer = Cli.ask('この台に、ルールの取得・照合・ipset の入れ替えを流す')
  unless answer
    warn(answer.nil? ? '端末がないので確かめられない。止める' : '止めた')
    exit 2
  end

  # 4. Run Command を送る（ルールの適用スクリプトの前に、渡す値を付ける）
  script = ["export PG_S3_URI='#{s3_uri}'", "export PG_REGION='#{region}'",
            "export PG_APPLY_IPV6='#{options[:ipv6] ? 1 : 0}'"] + File.readlines(REMOTE_SCRIPT, chomp: true)
  command = AwsCli.run('ssm', 'send-command',
                       '--document-name', 'AWS-RunShellScript',
                       '--instance-ids', *ids,
                       '--max-concurrency', '1', '--max-errors', '0',
                       '--timeout-seconds', '600',
                       '--comment', "port-guard apply rules #{options[:env]}",
                       '--parameters', JSON.generate('commands' => script, 'executionTimeout' => ['600']))['Command']
  command_id = command['CommandId']
  puts "Run Command を送った: #{command_id}"

  # 5. 全台が終わるまで待つ（PROGRESS_SECONDS ごとに進み具合を出す）
  started = Time.now
  last_progress = started
  statuses = {}
  loop do
    invocations = AwsCli.run('ssm', 'list-command-invocations', '--command-id', command_id)['CommandInvocations']
    statuses = invocations.to_h { |item| [item['InstanceId'], item['Status']] }
    command_status = AwsCli.run('ssm', 'list-commands', '--command-id', command_id)['Commands'].first['Status']
    break if TERMINAL.include?(command_status)

    if Time.now - last_progress >= PROGRESS_SECONDS
      puts "待っている（#{(Time.now - started).round} 秒）: #{statuses.map { |id, status| "#{id}=#{status}" }.join(' ')}"
      last_progress = Time.now
    end
    sleep POLL_SECONDS
  end

  # 6. 台ごとの結果を表示する
  results = ids.map do |id|
    status = statuses[id] || 'NotStarted'
    puts "== #{id}: #{status}"
    if statuses[id] && status != 'Cancelled'
      detail = AwsCli.run('ssm', 'get-command-invocation', '--command-id', command_id, '--instance-id', id)
      puts detail['StandardOutputContent'].to_s.rstrip
      error = detail['StandardErrorContent'].to_s.rstrip
      puts "（標準エラー）\n#{error}" unless error.empty?
    end
    status
  end
rescue AwsCli::Error => e
  warn "AWS のエラー: #{e.summary}"
  exit 3
end

succeeded = results.count('Success')
puts "結果: #{succeeded}/#{ids.size} 台が Success"
exit(succeeded == ids.size ? 0 : 1)
