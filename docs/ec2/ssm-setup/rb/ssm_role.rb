#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_role.rb [--instance-profile port-guard-ssm] [--check-only] [--yes] < instance-ids.txt
require 'optparse'
require_relative 'lib'

# IAM ロールが未設定のインスタンスに、SSM 用のインスタンスプロファイル（用意しておく）を関連付ける。
# すでにロールがある台には何もしない（ロールに権限を足すこともしない）。
# 公開のメソッドが流れの大枠の 4 段、private の下がヘルパ。
class SsmRole
  CORE_POLICY = 'AmazonSSMManagedInstanceCore'

  def initialize(profile)
    @profile = profile
  end

  # 流れ: インスタンスの存在チェック → ロールの状態チェック → ロールの付与 → 権限状態の確認
  def run(ids, check_only: false, assume_yes: false)
    instances, skipped = check_instances_exist(ids)
    to_attach = check_role_state(instances)
    return exit_code(skipped) if check_only || to_attach.empty?
    return 0 unless confirmed?(assume_yes)

    attached = attach_role(to_attach)
    permitted = verify_permissions(attached)
    exit_code(skipped, all_done: permitted && attached == to_attach)
  end

  # 1. インスタンスの存在チェック: running・stopped のインスタンス（ID → 「状態  Name」）と、対象外の ID を返す
  def check_instances_exist(ids)
    labels = instance_labels(ids)
    skipped = ids.reject { |id| labels[id]&.start_with?('running', 'stopped') }
    skipped.each { |id| puts "対象外      #{id}  #{labels[id] || '見つからない'}" }
    [labels.slice(*(ids - skipped)), skipped]
  end

  # 2. ロールの状態チェック: すでにロールがある台は何もしない。ロールがない台（付与する台）の ID を返す
  def check_role_state(instances)
    profiles = associated_profile_arns(instances.keys)
    instances.each do |id, label|
      puts profiles[id] ? "何もしない  #{id}  #{label}  #{profiles[id]}" : "付与する    #{id}  #{label}"
    end
    instances.keys - profiles.keys
  end

  # 3. ロールの付与: インスタンスプロファイルがあることを確かめてから、1 台ずつ関連付ける。関連付けた台を返す
  def attach_role(ids)
    aws_or_exit('iam', 'get-instance-profile', '--instance-profile-name', @profile)
    ids.select { |id| associate(id) }
  end

  # 4. 権限状態の確認: 関連付けが残っていて、そのロールに AmazonSSMManagedInstanceCore が付いているか
  def verify_permissions(ids)
    return true if ids.empty?

    associated = associated_profile_arns(ids)
    ids.each { |id| puts "関連付け    #{id}  #{associated[id] ? 'あり' : 'なし'}" }
    core = core_policy_attached?
    puts "権限        #{@profile} のロールに #{CORE_POLICY} が#{core ? '付いている' : '付いていない（Online にならない）'}"
    puts 'SSM に登録される（Online）まで数分かかることがある。少し時間を置いてから rb/ssm_check.rb で確かめる'
    core && associated.size == ids.size
  end

  private

  # 対象外の台がなく、行ったことがすべて済んでいれば 0
  def exit_code(skipped, all_done: true)
    all_done && skipped.empty? ? 0 : 1
  end

  def confirmed?(assume_yes)
    return true if assume_yes || Tools.ask("「付与する」の台に、インスタンスプロファイル #{@profile} を関連付けますか？")

    puts '中止した'
    false
  end

  def associate(id)
    Tools.aws('ec2', 'associate-iam-instance-profile',
              '--instance-id', id, '--iam-instance-profile', "Name=#{@profile}")
    puts "付与した    #{id}"
    true
  rescue Tools::AwsError => e # 確かめた後にほかの人が関連付けていたら、AWS の側が拒む（IncorrectState）
    puts "失敗        #{id}  #{e.message}"
    false
  end

  # インスタンスの ID → 「状態  Name」（見つからないインスタンスは入らない）
  def instance_labels(ids)
    reservations = aws_or_exit('ec2', 'describe-instances', '--filters', instance_filter(ids))['Reservations']
    reservations.flat_map { |r| r['Instances'] }.to_h do |instance|
      [instance['InstanceId'], "#{instance.dig('State', 'Name')}  #{name_tag(instance)}"]
    end
  end

  def name_tag(instance)
    (instance['Tags'] || []).find { |t| t['Key'] == 'Name' }&.fetch('Value')
  end

  # インスタンスの ID → 関連付けられているインスタンスプロファイルの ARN
  def associated_profile_arns(ids)
    associations = aws_or_exit('ec2', 'describe-iam-instance-profile-associations', '--filters', instance_filter(ids))
    associations['IamInstanceProfileAssociations']
      .select { |a| %w[associated associating].include?(a['State']) }
      .to_h { |a| [a['InstanceId'], a.dig('IamInstanceProfile', 'Arn')] }
  end

  def core_policy_attached?
    profile = aws_or_exit('iam', 'get-instance-profile', '--instance-profile-name', @profile)
    roles = profile.dig('InstanceProfile', 'Roles')
    roles.any? do |role|
      policies = aws_or_exit('iam', 'list-attached-role-policies', '--role-name', role['RoleName'])['AttachedPolicies']
      policies.any? { |p| p['PolicyName'] == CORE_POLICY }
    end
  end

  # まとめて読む（AWS のフィルターの値は 200 個まで）
  def instance_filter(ids)
    "Name=instance-id,Values=#{ids.join(',')}"
  end

  # 読めないときは、何もせずに止まる（終了コード 2）
  def aws_or_exit(*args)
    Tools.aws(*args)
  rescue Tools::AwsError => e
    warn "止めた: #{e.message}"
    exit 2
  end
end

def parse_options
  options = { profile: 'port-guard-ssm' }
  OptionParser.new do |o|
    o.on('--instance-profile NAME') { |v| options[:profile] = v }
    o.on('--check-only') { options[:check_only] = true }
    o.on('--yes') { options[:yes] = true }
  end.parse!
  options
end

options = parse_options
exit SsmRole.new(options[:profile]).run(Tools.read_ids, check_only: options[:check_only], assume_yes: options[:yes])
