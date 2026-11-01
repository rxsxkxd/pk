#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_check.rb [--ok-out enabled.txt] [--ng-out ng.txt] < instance-ids.txt
require 'optparse'
require_relative 'lib'

# SSM が使える状態かを、AWS の上の情報だけで確かめる（インスタンスには何も送らない。設定も変えない）。
# 1 台ずつ、状態、インスタンスプロファイルのロール、そのロールの AmazonSSMManagedInstanceCore、登録（Online）を見て、
# 3 つに分ける。実際につながるかは、--ok-out の一覧を rb/ssm_connect_check.rb に渡して確かめる。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SsmCheck
  CORE_POLICY = 'AmazonSSMManagedInstanceCore'
  LABELS = { enabled: 'SSM 有効', fixable_by_agent: 'SSM Agent で直す' }.freeze

  def initialize(ok_out:, ng_out:)
    @ok_out = ok_out
    @ng_out = ng_out
    @core_policy_cache = Hash.new { |cache, role| cache[role] = core_policy_attached?(role) } # 同じロールは 1 回だけ読む
  end

  # 流れ: 1 台ずつ確かめて分ける → 一覧を書き出す → 結果を表示する
  def run(ids)
    results = check_all(ids)
    write_lists(results)
    print_summary(results)
    all_enabled?(results) ? 0 : 1
  end

  # 1 台ずつ確かめて、区分（SSM 有効・SSM Agent で直す・手で直す）ごとに、一覧に書く行を集める
  def check_all(ids)
    results = { enabled: [], fixable_by_agent: [], fix_by_hand: [] }
    ids.each do |id|
      kind, line = check_instance(id)
      results[kind] << line
    end
    results
  end

  # 一覧を書き出す（--ok-out は ssm_connect_check.rb へ、--ng-out はバックアップと ssm-agent へ）
  def write_lists(results)
    write_list(@ok_out, '# SSM 有効の台（rb/ssm_connect_check.rb の標準入力に渡す）', results[:enabled])
    write_list(@ng_out, '# SSM Agent で直す台（バックアップと ssm-agent に渡せる）。手で直す台は行の先頭を # にして残す',
               results[:fixable_by_agent] + results[:fix_by_hand])
  end

  def print_summary(results)
    puts "== 結果: SSM 有効 #{results[:enabled].size} 台、SSM Agent で直す #{results[:fixable_by_agent].size} 台、" \
         "手で直す #{results[:fix_by_hand].size} 台"
  end

  private

  def all_enabled?(results)
    results[:fixable_by_agent].empty? && results[:fix_by_hand].empty?
  end

  # 1 台を確かめて表示し、[区分, 一覧に書く行] を返す
  def check_instance(id)
    status = gather_status(id)
    print_status(id, status)
    case (verdict = classify(status))
    when :enabled, :fixable_by_agent
      puts "   #{LABELS[verdict]}"
      [verdict, id]
    else
      puts "   手で直す: #{verdict}"
      [:fix_by_hand, "# #{id}  # #{verdict}"]
    end
  end

  def gather_status(id)
    role = attached_role_name(id)
    { state: instance_state(id), role: role, core_policy: role && @core_policy_cache[role],
      registration: registration_status(id) }
  end

  def print_status(id, status)
    core_policy = status[:core_policy] ? 'あり' : 'なし'
    puts "== #{id}  状態 #{status[:state]}  ロール #{status[:role] || 'なし'}（#{CORE_POLICY} #{core_policy}）  " \
         "登録 #{status[:registration]}"
  end

  # :enabled（SSM 有効）、:fixable_by_agent（SSM Agent で直す）、または手で直す理由の文字列
  def classify(status)
    return :enabled if status[:registration] == 'Online'

    reason_to_fix_by_hand(status) || :fixable_by_agent
  end

  # SSM Agent を入れ直しても直らない理由（当てはまらなければ nil）
  def reason_to_fix_by_hand(status)
    return "状態が #{status[:state] || '見つからない'}（running でない）" unless status[:state] == 'running'
    return '登録を読めない（作業者の権限 ssm:DescribeInstanceInformation を見る）' if status[:registration] == '読めない'
    return 'インスタンスプロファイルかロールがない（ssm-role を見直す）' unless status[:role]

    "ロールに #{CORE_POLICY} が付いていない、または読めない" unless status[:core_policy]
  end

  def instance_state(id)
    instances = aws_or_nil('ec2', 'describe-instances', '--instance-ids', id)
    instances&.dig('Reservations', 0, 'Instances', 0, 'State', 'Name')
  end

  # 関連付けられたインスタンスプロファイルに入っているロールの名前（なければ nil）
  def attached_role_name(id)
    filter = "Name=instance-id,Values=#{id}"
    associations = aws_or_nil('ec2', 'describe-iam-instance-profile-associations', '--filters', filter)
    association = associations&.fetch('IamInstanceProfileAssociations')&.find { |a| a['State'] == 'associated' }
    return nil unless association

    profile_name = association.dig('IamInstanceProfile', 'Arn').split('/').last
    profile = aws_or_nil('iam', 'get-instance-profile', '--instance-profile-name', profile_name)
    profile&.dig('InstanceProfile', 'Roles', 0, 'RoleName')
  end

  def core_policy_attached?(role)
    policies = aws_or_nil('iam', 'list-attached-role-policies', '--role-name', role)
    (policies&.fetch('AttachedPolicies') || []).any? { |p| p['PolicyName'] == CORE_POLICY }
  end

  # SSM の登録の状態（Online・ConnectionLost など。登録がなければ「未登録」、読めなければ「読めない」）
  def registration_status(id)
    info = aws_or_nil('ssm', 'describe-instance-information', '--filters', "Key=InstanceIds,Values=#{id}")
    info ? info.dig('InstanceInformationList', 0, 'PingStatus') || '未登録' : '読めない'
  end

  # 読めなければ nil（読めないことも、手で直す理由として表示する）
  def aws_or_nil(*args)
    Tools.aws(*args)
  rescue Tools::AwsError
    nil
  end

  def write_list(path, header, lines)
    File.write(path, [header, *lines].map { |line| "#{line}\n" }.join)
  end
end

def parse_options
  options = { ok_out: File::NULL, ng_out: File::NULL }
  OptionParser.new do |o|
    o.on('--ok-out PATH') { |v| options[:ok_out] = v }
    o.on('--ng-out PATH') { |v| options[:ng_out] = v }
  end.parse!
  options
end

exit SsmCheck.new(**parse_options).run(Tools.read_ids)
