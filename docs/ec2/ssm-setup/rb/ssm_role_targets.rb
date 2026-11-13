#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_role_targets.rb [--out role-targets.txt] < instance-ids.txt
require_relative 'lib/cli'

# rb/ssm_role_force.rb に渡す一覧（インスタンスプロファイルを付与できる台だけ）を作る（読み取りだけ。何も変えない）。
# rb/ssm_role.rb の「確かめる」の部分（1. インスタンスの存在チェック、2. ロールの状態チェック）だけを行い、
# 付与できる・何もしない（すでに IAM ロールがある）・対象外（running・stopped でない、見つからない）に分けて表示する。
# --out で、付与できる台だけの一覧を書き出す。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SsmRoleTargets
  def initialize(out: nil)
    @out = out
  end

  # 流れ: 存在と状態を読む → 関連付けを読む → 分けて表示する → 一覧を書き出す
  def run(ids)
    instances = describe_instances(ids)
    profiles = associated_profiles(instances.keys)
    groups = classify(ids, instances, profiles)
    print_groups(groups)
    write_targets(groups[:targets].map(&:first)) if @out
    0
  rescue AwsCli::Error => e
    puts "止めた: #{e.summary}"
    2
  end

  # インスタンスの ID → [名前, 状態]（見つからないインスタンスは入らない）
  def describe_instances(ids)
    ids.each_slice(200).with_object({}) do |slice, result| # フィルターの値は 200 個まで
      AwsCli.run('ec2', 'describe-instances', '--filters', "Name=instance-id,Values=#{slice.join(',')}")['Reservations']
            .flat_map { |reservation| reservation['Instances'] }.each do |instance|
        result[instance['InstanceId']] = [instance_name(instance), instance.dig('State', 'Name')]
      end
    end
  end

  # インスタンスの ID → 関連付けられているインスタンスプロファイルの ARN（関連付けがない台は入らない）
  def associated_profiles(ids)
    ids.each_slice(200).with_object({}) do |slice, result|
      AwsCli.run('ec2', 'describe-iam-instance-profile-associations', '--filters',
                 "Name=instance-id,Values=#{slice.join(',')}")['IamInstanceProfileAssociations'].each do |association|
        next unless %w[associating associated].include?(association['State'])

        result[association['InstanceId']] = association.dig('IamInstanceProfile', 'Arn')
      end
    end
  end

  private

  def instance_name(instance)
    (instance['Tags'] || []).find { |tag| tag['Key'] == 'Name' }&.fetch('Value').to_s
  end

  # { targets: [[ID, 表示の行]], keep: [...], excluded: [...] }
  def classify(ids, instances, profiles)
    groups = { targets: [], keep: [], excluded: [] }
    ids.each do |id|
      name, state = instances[id] # 見つからなければ両方 nil
      key, line = sort_one(id, name, state, profiles[id])
      groups[key] << [id, line]
    end
    groups
  end

  # [区分, 表示の行]
  def sort_one(id, name, state, profile_arn)
    unless %w[running stopped].include?(state)
      return [:excluded, "#{id}  #{name}  理由: #{state ? "状態が #{state}" : '見つからない'}"]
    end
    return [:keep, "#{id}  #{name}  すでに IAM ロールがある: #{profile_arn}"] if profile_arn

    [:targets, "#{id}  #{name}  #{state}"]
  end

  def print_groups(groups)
    { targets: '付与できる（IAM ロールが未設定）', keep: '何もしない（すでに IAM ロールがある）', excluded: '対象外' }
      .each do |key, title|
        puts "\n== #{title}（#{groups[key].size} 台）"
        groups[key].each { |entry| puts "  #{entry[1]}" }
      end
  end

  def write_targets(ids)
    Cli.write_list(@out, 'ssm_role_targets.rb で、インスタンスプロファイルを付与できる台（ssm_role_force.rb の標準入力に渡す）', ids)
    puts "\n付与できる台の一覧を書き出した: #{@out}（#{ids.size} 台）"
  end
end

if $PROGRAM_NAME == __FILE__
  options = Cli.parse_options do |o, opts|
    o.on('--out PATH', '付与できる台を書き出す（ssm_role_force.rb の標準入力に渡す）') { |v| opts[:out] = v }
  end
  Cli.require_aws_cli
  exit SsmRoleTargets.new(out: options[:out]).run(Cli.read_ids)
end
