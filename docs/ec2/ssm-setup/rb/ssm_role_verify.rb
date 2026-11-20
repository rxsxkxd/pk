#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_role_verify.rb [--instance-profile port-guard-ssm] [--ok-out role-ok.txt] < instance-ids.txt
require_relative 'lib/cli'

# ロールの付与状態だけを確かめる（読み取りだけ。何も変えない）。rb/ssm_role.rb の「4. 権限状態の確認」を単独で流す版。
# 1 台ずつ、インスタンスプロファイルが関連付けられているか、その中のロールに AmazonSSMManagedInstanceCore が
# 付いているかを見る。SSM の登録（Online か）は見ない（付与の直後でも、ロールが正しく付いていれば「付いている」になる）。
# --instance-profile を付けると、関連付けられているのがそのインスタンスプロファイルかも見る。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SsmRoleVerify
  CORE_POLICY = 'AmazonSSMManagedInstanceCore'

  def initialize(expected_profile: nil, ok_out: nil)
    @expected_profile = expected_profile
    @ok_out = ok_out
    @profile_cache = {} # インスタンスプロファイルの名前 → 問題（nil なら問題なし）。同じものは 1 回だけ読む
  end

  # 流れ: 関連付けをまとめて読む → 1 台ずつ確かめて表示する → 結果を表示する → 一覧を書き出す
  def run(ids)
    puts "#{ids.size} 台のロールの付与状態を確かめる（読み取りだけ。SSM の登録は見ない）"
    profiles = associated_profiles(ids)
    problems = ids.to_h { |id| [id, problem_of(profiles[id])] }
    fine, broken = ids.partition { |id| problems[id].nil? }
    print_result(fine, broken, profiles, problems)
    write_ok_list(fine) if @ok_out
    broken.empty? ? 0 : 1
  rescue AwsCli::Error => e
    puts "止めた: #{e.summary}"
    2
  end

  # インスタンスの ID → 関連付けられているインスタンスプロファイルの名前（関連付けがない台は入らない）
  def associated_profiles(ids)
    ids.each_slice(200).with_object({}) do |slice, result| # フィルターの値は 200 個まで
      AwsCli.run('ec2', 'describe-iam-instance-profile-associations', '--filters',
                 "Name=instance-id,Values=#{slice.join(',')}")['IamInstanceProfileAssociations'].each do |association|
        next unless %w[associating associated].include?(association['State'])

        # ARN にパスがあっても、最後の部分が名前
        result[association['InstanceId']] = association.dig('IamInstanceProfile', 'Arn').split('/').last
      end
    end
  end

  private

  # 1 台の問題（nil なら、正しく付いている）
  def problem_of(profile)
    return 'インスタンスプロファイルが関連付けられていない' unless profile
    return "関連付けられているのが #{@expected_profile} ではない（#{profile}）" if unexpected?(profile)

    @profile_cache.fetch(profile) { @profile_cache[profile] = profile_problem(profile) }
  end

  def unexpected?(profile)
    @expected_profile && profile != @expected_profile
  end

  # インスタンスプロファイルの中のロールに AmazonSSMManagedInstanceCore が付いているか。問題がなければ nil
  def profile_problem(profile)
    roles = AwsCli.run('iam', 'get-instance-profile', '--instance-profile-name', profile)
                  .dig('InstanceProfile', 'Roles').map { |role| role['RoleName'] }
    return "インスタンスプロファイル #{profile} にロールが入っていない" if roles.empty?
    return nil if roles.any? { |role| core_policy?(role) }

    "#{profile} のロール（#{roles.join(', ')}）に #{CORE_POLICY} が付いていない"
  rescue AwsCli::Error => e
    "確かめられない（#{e.summary}）"
  end

  def core_policy?(role)
    AwsCli.run('iam', 'list-attached-role-policies', '--role-name', role)['AttachedPolicies']
          .any? { |policy| policy['PolicyArn'].end_with?(":policy/#{CORE_POLICY}") }
  end

  def print_result(fine, broken, profiles, problems)
    puts "\n== 付いている（#{fine.size} 台）"
    fine.each { |id| puts "  #{id}  #{profiles[id]}" }
    puts "\n== 付いていない・問題がある（#{broken.size} 台）"
    broken.each { |id| puts "  #{id}  理由: #{problems[id]}" }
    puts "\n== 結果: 付いている #{fine.size} 台、付いていない・問題がある #{broken.size} 台",
         'SSM に登録される（Online）まで数分かかることがある。登録まで見るなら ssm_check.rb で確かめる'
  end

  def write_ok_list(fine)
    Cli.write_list(@ok_out, "ssm_role_verify.rb で、ロールが正しく付いていた台（#{CORE_POLICY} あり）", fine)
    puts "付いている台の一覧を書き出した: #{@ok_out}（#{fine.size} 台）"
  end
end

if $PROGRAM_NAME == __FILE__
  options = Cli.parse_options do |o, opts|
    o.on('--instance-profile NAME', '関連付けられているのが、このインスタンスプロファイルかも確かめる（省略すると見ない）') do |v|
      opts[:profile] = v
    end
    o.on('--ok-out PATH', 'ロールが正しく付いていた台を書き出す') { |v| opts[:ok_out] = v }
  end
  Cli.require_aws_cli
  exit SsmRoleVerify.new(expected_profile: options[:profile], ok_out: options[:ok_out]).run(Cli.read_ids)
end
