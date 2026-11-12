#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_check.rb [--ok-out enabled.txt] [--ng-out ng.txt] < instance-ids.txt
require 'optparse'
require_relative 'host_state'

# SSM が使える状態かを、権限と AWS の上のインスタンスの状態だけで確かめる（ssm_role.rb の後に使う）。
# インスタンスには何も送らない（設定も変えない）。1 台ずつ確かめて（rb/host_state.rb）、次の 3 つに分ける。
# - SSM 有効: Online → connect/ssm-connect-check.sh で実際に入れるかを確かめる
# - SSM Agent で直す: running で、ロールに AmazonSSMManagedInstanceCore が付いているのに Online でない
#   → backup.rb でバックアップを取ってから、SSM Agent の導入（instance/）
# - 手で直す: それ以外（止まっている、インスタンスプロファイルがない、ロールに権限がない見込み、など）
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SsmCheck
  TITLES = {
    HostState::OK => 'SSM 有効（Online）→ connect/ssm-connect-check.sh で実際に入れるかを確かめる',
    HostState::AGENT => 'SSM 有効でない: SSM Agent で直す見込み → backup.rb、SSM Agent の導入（instance/）',
    HostState::MANUAL => 'SSM 有効でない: 手で直す（SSM Agent の導入では直らない見込み）'
  }.freeze

  def initialize(ok_out: nil, ng_out: nil)
    @ok_out = ok_out
    @ng_out = ng_out
  end

  # 流れ: 1 台ずつ確かめる → 3 つに分けて表示する → 一覧を書き出す
  def run(ids)
    hosts = inspect_all(ids)
    groups = TITLES.keys.to_h { |category| [category, hosts.select { |host| host.category == category }] }
    print_groups(groups, hosts.count(&:no_core_policy?))
    write_lists(groups)
    groups[HostState::OK].size == hosts.size ? 0 : 1
  end

  private

  def inspect_all(ids)
    puts "#{ids.size} 台を確かめる（権限と AWS の上の状態だけ。インスタンスには何も送らない）"
    policy_cache = {}
    ids.map do |id|
      puts "  確認中: #{id}"
      HostState.new(id, policy_cache).inspect!
    end
  end

  def print_groups(groups, no_policy)
    groups.each do |category, hosts|
      puts "\n== #{TITLES[category]}（#{hosts.size} 台）"
      hosts.each { |host| host.lines.each { |line| puts "  #{line}" } }
    end
    counts = groups.map { |category, hosts| "#{category} #{hosts.size} 台" }.join('、')
    puts "\n== 結果: #{counts}（#{SsmSetup::CORE_POLICY} が付いていないもの #{no_policy} 台）"
  end

  def write_lists(groups)
    write_ok_list(groups[HostState::OK]) if @ok_out
    write_ng_list(groups[HostState::AGENT], groups[HostState::MANUAL]) if @ng_out
  end

  # 「SSM 有効」の台の一覧（connect/ssm-connect-check.sh の標準入力の形）
  def write_ok_list(hosts)
    SsmSetup.write_list(@ok_out, 'ssm_check.rb で SSM 有効の台（connect/ssm-connect-check.sh の標準入力に渡す）',
                        hosts.map { |host| host.name.empty? ? host.id : "#{host.id}  # #{host.name}" })
    puts "SSM 有効の台の一覧を書き出した: #{@ok_out}（#{hosts.size} 台）"
  end

  # 「SSM Agent で直す」台の一覧（backup.rb・backup_check.rb の標準入力の形。理由は # の後ろ）。
  # 手で直す台は、行の先頭を # にして残す（読み飛ばされる）
  def write_ng_list(agent, manual)
    lines = agent.map { |host| "#{host.id}  # #{host.problems.join(' / ')}" }
    unless manual.empty?
      lines += ['', '# 手で直す台（SSM Agent の導入では直らない見込み。行の先頭が # なので読み飛ばされる）']
      lines += manual.map { |host| "# #{host.id}  # #{host.problems.join(' / ')}  見るところ: #{host.hint}" }
    end
    SsmSetup.write_list(@ng_out, 'ssm_check.rb で SSM Agent で直す見込みの台（backup.rb・backup_check.rb の標準入力に渡す）', lines)
    puts "SSM Agent で直す台の一覧を書き出した: #{@ng_out}（#{agent.size} 台。手で直す #{manual.size} 台は # で残した）"
  end
end

if $PROGRAM_NAME == __FILE__
  options = SsmSetup.parse_options do |o, opts|
    o.on('--ok-out PATH', '「SSM 有効」の台を書き出す（connect/ssm-connect-check.sh の標準入力に渡す）') { |v| opts[:ok_out] = v }
    o.on('--ng-out PATH', '「SSM Agent で直す」台を書き出す（backup.rb・backup_check.rb の標準入力に渡す）') { |v| opts[:ng_out] = v }
  end
  SsmSetup.require_aws_cli
  exit SsmCheck.new(ok_out: options[:ok_out], ng_out: options[:ng_out]).run(Tools.read_ids)
end
