#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_role.rb [--instance-profile port-guard-ssm] [--check-only] [--yes] < instance-ids.txt
require_relative 'lib/flow'

# IAM ロールが未設定のインスタンスに、SSM 用のインスタンスプロファイルを関連付ける。
# すでにロールがある台には何もしない（ロールの付け替えも、そのロールに権限を足すこともしない）。
# 流れ: 1. インスタンスの存在チェック → 2. ロールの状態チェック → 3. ロールの付与 → 4. 権限状態の確認。
# インスタンスプロファイルは道具では作らない（なければ止まる）。SSM に登録される（Online）のは待たないので、
# 少し時間を置いてから ssm_check.rb で確かめる。
# 確かめるところを外して付与だけを行う版は rb/ssm_role_force.rb（渡す一覧は rb/ssm_role_targets.rb で作る）。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SsmRole
  DEFAULT_PROFILE = 'port-guard-ssm'
  CORE_POLICY = 'AmazonSSMManagedInstanceCore'

  def initialize(profile_name)
    @profile_name = profile_name
  end

  def run(ids, check_only: false, assume_yes: false)
    plan = Flow.plan { make_plan(ids) }
    Flow.execute(plan, heading: 'ロールの付与（1 台ずつ順に行う）', check_only: check_only, assume_yes: assume_yes) do |item|
      attach_role(item.id)
    end
  end

  # 1・2 を確かめて、付与する・何もしない・対象外に分ける
  def make_plan(ids)
    instances = check_instances_exist(ids)
    profiles = check_role_state(instances.keys)
    plan = Flow::Plan.new(title: "付与する（IAM ロールが未設定）→ #{@profile_name}",
                          question: "インスタンスプロファイル #{@profile_name} を関連付けますか？")
    plan.finish = ->(done) { verify_permissions(done) }
    ids.each { |id| sort_into(plan, id, instances[id], profiles[id]) }
    profile_roles unless plan.todo.empty? # インスタンスプロファイルがなければ、ここで止まる
    plan
  end

  # 1. インスタンスの存在チェック。インスタンスの ID → [名前, 状態]（見つからないインスタンスは入らない）
  def check_instances_exist(ids)
    ids.each_slice(200).with_object({}) do |slice, result| # フィルターの値は 200 個まで
      AwsCli.run('ec2', 'describe-instances', '--filters', "Name=instance-id,Values=#{slice.join(',')}")['Reservations']
            .flat_map { |reservation| reservation['Instances'] }.each do |instance|
        result[instance['InstanceId']] = [instance_name(instance), instance.dig('State', 'Name')]
      end
    end
  end

  # 2. ロールの状態チェック。インスタンスの ID → 関連付けられているインスタンスプロファイルの ARN
  def check_role_state(ids)
    ids.empty? ? {} : associated_profiles(ids)
  end

  # 3. ロールの付与
  def attach_role(id)
    # [変更] インスタンスプロファイルを関連付ける
    AwsCli.run('ec2', 'associate-iam-instance-profile', '--instance-id', id,
               '--iam-instance-profile', "Name=#{@profile_name}")
    nil
  end

  # 4. 権限状態の確認。関連付けが残っていて、ロールに AmazonSSMManagedInstanceCore が付いていれば true
  def verify_permissions(done)
    puts "\n== 権限状態の確認"
    associated = associated_profiles(done.map(&:id))
    core = profile_roles.any? { |role| core_policy?(role) }
    print_permissions(done, associated, core)
    core && done.all? { |item| associated.key?(item.id) }
  rescue AwsCli::Error => e
    puts "  確かめられない（#{e.summary}）"
    false
  end

  private

  def instance_name(instance)
    (instance['Tags'] || []).find { |tag| tag['Key'] == 'Name' }&.fetch('Value').to_s
  end

  def sort_into(plan, id, instance, profile_arn)
    name, state = instance
    if !%w[running stopped].include?(state)
      plan.excluded << "#{id}  #{name}  理由: #{state ? "状態が #{state}" : '見つからない'}"
    elsif profile_arn
      plan.keep << "#{id}  #{name}  すでに IAM ロールがある: #{profile_arn}"
    else
      plan.todo << Flow::Item.new(id, "#{id}  #{name}")
    end
  end

  # インスタンスの ID → 関連付けられているインスタンスプロファイルの ARN（関連付けがない台は入らない）
  def associated_profiles(ids)
    ids.each_slice(200).with_object({}) do |slice, result| # フィルターの値は 200 個まで
      AwsCli.run('ec2', 'describe-iam-instance-profile-associations', '--filters',
                 "Name=instance-id,Values=#{slice.join(',')}")['IamInstanceProfileAssociations'].each do |association|
        next unless %w[associating associated].include?(association['State'])

        result[association['InstanceId']] = association.dig('IamInstanceProfile', 'Arn')
      end
    end
  end

  # 関連付けるインスタンスプロファイルの中のロールの名前の一覧（インスタンスプロファイルがなければ AwsCli::Error）
  def profile_roles
    AwsCli.run('iam', 'get-instance-profile', '--instance-profile-name',
               @profile_name).dig('InstanceProfile', 'Roles').map { |role| role['RoleName'] }
  end

  def core_policy?(role)
    AwsCli.run('iam', 'list-attached-role-policies', '--role-name', role)['AttachedPolicies']
          .any? { |policy| policy['PolicyArn'].end_with?(":policy/#{CORE_POLICY}") }
  end

  def print_permissions(done, associated, core)
    done.each { |item| puts "  関連付け: #{item.id}  #{associated.key?(item.id) ? 'あり' : 'なし'}" }
    puts "  権限: #{@profile_name} のロールに #{CORE_POLICY} が" \
         "#{core ? '付いている' : '付いていない（このままでは Online にならない）'}"
    puts 'SSM に登録される（Online）まで数分かかることがある。少し時間を置いてから ssm_check.rb で確かめる'
  end
end

if $PROGRAM_NAME == __FILE__
  options = Cli.parse_options(profile: SsmRole::DEFAULT_PROFILE) do |o, opts|
    o.on('--instance-profile NAME', "関連付けるインスタンスプロファイル（既定 #{SsmRole::DEFAULT_PROFILE}。先に作っておく）") do |v|
      opts[:profile] = v
    end
    Cli.define_run_options(o, opts, 'インスタンスプロファイルの関連付け')
  end
  Cli.require_aws_cli
  exit SsmRole.new(options[:profile]).run(Cli.read_ids, check_only: options[:check_only], assume_yes: options[:yes])
end
