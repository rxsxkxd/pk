#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_role_force.rb [--instance-profile port-guard-ssm] [--check-only] [--yes] < role-targets.txt
require_relative 'lib/flow'

# 渡した台に、SSM 用のインスタンスプロファイルを強制的に関連付ける（rb/ssm_role.rb の「行う」の部分だけ）。
# rb/ssm_role.rb の必須でない確かめ（インスタンスの存在チェック、ロールの状態チェック、インスタンスプロファイルがあるか、
# 付与の後の権限状態の確認）は行わない。渡す一覧は、付与できる台だけの一覧（rb/ssm_role_targets.rb の --out）を想定する。
# すでに関連付けがある台・見つからない台・インスタンスプロファイルがないときは、AWS の側が拒み、その台の失敗として表示する。
# 試行するかの確認（[y/N]・--yes・--check-only）はある。公開のメソッドが流れの大枠、private の下がヘルパ。
class SsmRoleForce
  DEFAULT_PROFILE = 'port-guard-ssm'

  def initialize(profile_name)
    @profile_name = profile_name
  end

  # 流れ: 一覧を表示する → [y/N] の確認 → 1 台ずつ関連付ける
  def run(ids, check_only: false, assume_yes: false)
    plan = Flow::Plan.new(title: "付与する（確かめずに関連付ける）→ #{@profile_name}",
                          question: "インスタンスプロファイル #{@profile_name} を関連付けますか？", keep_title: nil)
    ids.each { |id| plan.todo << Flow::Item.new(id, id) }
    Flow.execute(plan, heading: 'ロールの付与（1 台ずつ順に行う）', check_only: check_only, assume_yes: assume_yes) do |item|
      attach_role(item.id)
    end
  end

  def attach_role(id)
    # [変更] インスタンスプロファイルを関連付ける
    AwsCli.run('ec2', 'associate-iam-instance-profile', '--instance-id', id,
               '--iam-instance-profile', "Name=#{@profile_name}")
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  options = Cli.parse_options(profile: SsmRoleForce::DEFAULT_PROFILE) do |o, opts|
    o.on('--instance-profile NAME', "関連付けるインスタンスプロファイル（既定 #{SsmRoleForce::DEFAULT_PROFILE}。先に作っておく）") do |v|
      opts[:profile] = v
    end
    Cli.define_run_options(o, opts, 'インスタンスプロファイルの関連付け')
  end
  Cli.require_aws_cli
  exit SsmRoleForce.new(options[:profile]).run(Cli.read_ids, check_only: options[:check_only],
                                                             assume_yes: options[:yes])
end
