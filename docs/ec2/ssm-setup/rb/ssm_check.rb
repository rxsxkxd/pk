#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_check.rb [--ok-out enabled.txt] [--ng-out ng.txt] < instance-ids.txt
require_relative 'lib/cli'

# SSM が使える状態かを、権限と AWS の上のインスタンスの状態だけで確かめる（ssm_role.rb の後に使う）。
# インスタンスには何も送らない（設定も変えない）。1 台ずつ確かめて（HostState）、次の 3 つに分ける。
# - SSM 有効: Online → command/connect/ssm-connect-check.sh で実際に入れるかを確かめる
# - SSM Agent で直す: running で、ロールに AmazonSSMManagedInstanceCore が付いているのに Online でない
#   → backup.rb でバックアップを取ってから、SSM Agent の導入（command/instance/）
# - 手で直す: それ以外（止まっている、インスタンスプロファイルがない、ロールに権限がない見込み、など）
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SsmCheck
  # ssm_check.rb だけで使う AWS の読み方（AWS の機能の仕様に紐づくので、lib/ には置かない）
  module Reads
    CORE_POLICY = 'AmazonSSMManagedInstanceCore'
    NOT_FOUND = %w[InvalidInstanceID.NotFound InvalidInstanceID.Malformed].freeze

    module_function

    # インスタンスの情報（describe-instances の 1 台分）。見つからなければ nil。ほかの失敗は AwsCli::Error
    def instance(id)
      AwsCli.run('ec2', 'describe-instances', '--instance-ids', id).dig('Reservations', 0, 'Instances', 0)
    rescue AwsCli::Error => e
      raise unless NOT_FOUND.include?(e.code)

      nil
    end

    # 関連付けられているインスタンスプロファイルの ARN（なければ nil）
    def profile_arn(id)
      AwsCli.run('ec2', 'describe-iam-instance-profile-associations', '--filters', "Name=instance-id,Values=#{id}")
            .fetch('IamInstanceProfileAssociations')
            .find { |association| %w[associating associated].include?(association['State']) }
            &.dig('IamInstanceProfile', 'Arn')
    end

    # インスタンスプロファイルの中のロールの名前の一覧
    def profile_roles(profile_name)
      AwsCli.run('iam', 'get-instance-profile', '--instance-profile-name',
                 profile_name).dig('InstanceProfile', 'Roles').map { |role| role['RoleName'] }
    end

    # ロールに付いている管理ポリシー（[名前, ARN] の一覧）
    def attached_policies(role)
      AwsCli.run('iam', 'list-attached-role-policies', '--role-name', role)['AttachedPolicies']
            .map { |policy| [policy['PolicyName'], policy['PolicyArn']] }
    end

    # ロールのインラインのポリシーの名前の一覧
    def inline_policies(role)
      AwsCli.run('iam', 'list-role-policies', '--role-name', role)['PolicyNames']
    end

    # SSM の登録の情報（describe-instance-information の 1 台分）。なければ nil
    def instance_information(id)
      AwsCli.run('ssm', 'describe-instance-information', '--filters',
                 "Key=InstanceIds,Values=#{id}")['InstanceInformationList'][0]
    end
  end

  # 1 台の状態（権限と AWS の上の状態だけ。インスタンスには何も送らない）。
  # インスタンス → インスタンスプロファイルとロール → ロールの AmazonSSMManagedInstanceCore（参考）→ SSM の登録 の順に読み、
  # SSM 有効・SSM Agent で直す・手で直す のどれかに分ける。
  class HostState
    OK = 'SSM 有効'
    AGENT = 'SSM Agent で直す'
    MANUAL = '手で直す'

    attr_reader :id, :name, :problems, :hint, :policy

    # policy_cache: ロールの名前 → ポリシーの確認の結果（同じロールは 1 回だけ読む）
    def initialize(id, policy_cache)
      @id = id
      @policy_cache = policy_cache
      @name = ''
      @roles = []
      @policy = ''
      @ping_status = ''
      @problems = []
    end

    # 読む: インスタンス → インスタンスプロファイルとロール → ポリシー（参考）→ 登録
    def inspect!
      return self unless read_instance

      read_profile
      @policy = @policy_cache[@roles[0]] ||= describe_policy(@roles[0]) unless @roles.empty?
      return not_running if @state != 'running'

      read_registration
      @problems << "SSM の登録が #{@ping_status}（Online でない）" unless @ping_status == 'Online'
      self
    end

    # SSM 有効・SSM Agent で直す・手で直す のどれか（SSM Agent の導入で直る見込みがあるものだけを AGENT にする）
    def category
      return OK if @problems.empty?

      @hint = manual_hint
      @hint ? MANUAL : AGENT
    end

    # ロールに AmazonSSMManagedInstanceCore が付いていないと分かったか
    def no_core_policy?
      @policy.start_with?("#{Reads::CORE_POLICY} が付いていない")
    end

    # 表示の行（1 行目がインスタンス、2 行目から詳細）
    def lines
      ["#{@id}  #{@name}  #{@state}"] + detail_lines.map { |line| "    #{line}" }
    end

    private

    # 読めたら true。見つからない・読めないなら、理由を problems に入れて false
    def read_instance
      instance = Reads.instance(@id)
      @problems << 'インスタンスが見つからない' unless instance
      return false unless instance

      @name = (instance['Tags'] || []).find { |tag| tag['Key'] == 'Name' }&.fetch('Value').to_s
      @state = instance.dig('State', 'Name').to_s
      true
    rescue AwsCli::Error => e
      @problems << "情報を取れない（#{e.summary}）"
      false
    end

    def read_profile
      @profile = Reads.profile_arn(@id).to_s.split('/').last.to_s # パスがあっても最後の部分が名前
      return @policy = 'インスタンスプロファイルがない' if @profile.empty?

      @roles = Reads.profile_roles(@profile)
      @policy = 'インスタンスプロファイルにロールが入っていない' if @roles.empty?
    rescue AwsCli::Error => e
      @policy = "確かめられない（インスタンスプロファイルを読めない: #{e.summary}）"
    end

    def describe_policy(role)
      policies = Reads.attached_policies(role)
      return "#{Reads::CORE_POLICY} が付いている" if policies.any? { |_, arn| arn.end_with?(":policy/#{Reads::CORE_POLICY}") }

      inline = Reads.inline_policies(role)
      "#{Reads::CORE_POLICY} が付いていない（要確認。付いているもの: #{join_or_none(policies.map(&:first))}、" \
        "インライン: #{join_or_none(inline)}）"
    rescue AwsCli::Error => e
      "確かめられない（ロールのポリシーを読めない: #{e.summary}）"
    end

    def read_registration
      information = Reads.instance_information(@id)
      @ping_status = information ? information['PingStatus'] : '未登録'
      @agent_version = information && information['AgentVersion']
    rescue AwsCli::Error => e
      @ping_status = "不明（#{e.code || e.summary}）"
    end

    def not_running
      @problems << "状態が #{@state}（running でなければ入れない）"
      self
    end

    # 手で直すときに見るところ。SSM Agent の導入で直る見込みなら nil
    def manual_hint
      return 'インスタンスの状態を見る（SSM Agent の導入は running の台にしか流せない）' if @state != 'running'
      return '登録の状態を読めない。作業者の権限（ssm:DescribeInstanceInformation）を見る' if @ping_status.start_with?('不明')
      return 'インスタンスプロファイルがない。ssm_role.rb を見直す' if @profile.to_s.empty?
      return 'インスタンスプロファイルにロールが入っていない' if @roles.empty?
      return nil unless no_core_policy?

      "ロールに #{Reads::CORE_POLICY} が付いていない（すでにあるロールなら、手で足すかを決める。" \
        '独自のポリシーで足りているのに Online でないなら、SSM Agent を疑い、一覧に戻す）'
    end

    def detail_lines
      lines = @state ? profile_lines : []
      lines << "登録: #{@ping_status}#{"（SSM Agent #{@agent_version}）" if @agent_version}" unless @ping_status.empty?
      lines + @problems.map { |problem| "理由: #{problem}" } + (@hint ? ["見るところ: #{@hint}"] : [])
    end

    def profile_lines
      roles = @profile.to_s.empty? ? '' : "（ロール: #{join_or_none(@roles)}）"
      ["インスタンスプロファイル: #{@profile.to_s.empty? ? 'なし' : @profile}#{roles}", "ポリシー: #{@policy}"]
    end

    def join_or_none(names)
      names.empty? ? 'なし' : names.join(', ')
    end
  end

  TITLES = {
    HostState::OK => 'SSM 有効（Online）→ command/connect/ssm-connect-check.sh で実際に入れるかを確かめる',
    HostState::AGENT => 'SSM 有効でない: SSM Agent で直す見込み → backup.rb、SSM Agent の導入（command/instance/）',
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
    puts "\n== 結果: #{counts}（#{Reads::CORE_POLICY} が付いていないもの #{no_policy} 台）"
  end

  def write_lists(groups)
    write_ok_list(groups[HostState::OK]) if @ok_out
    write_ng_list(groups[HostState::AGENT], groups[HostState::MANUAL]) if @ng_out
  end

  # 「SSM 有効」の台の一覧（command/connect/ssm-connect-check.sh の標準入力の形）
  def write_ok_list(hosts)
    Cli.write_list(@ok_out, 'ssm_check.rb で SSM 有効の台（command/connect/ssm-connect-check.sh の標準入力に渡す）',
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
    Cli.write_list(@ng_out, 'ssm_check.rb で SSM Agent で直す見込みの台（backup.rb・backup_check.rb の標準入力に渡す）', lines)
    puts "SSM Agent で直す台の一覧を書き出した: #{@ng_out}（#{agent.size} 台。手で直す #{manual.size} 台は # で残した）"
  end
end

if $PROGRAM_NAME == __FILE__
  options = Cli.parse_options do |o, opts|
    o.on('--ok-out PATH', '「SSM 有効」の台を書き出す（command/connect/ssm-connect-check.sh の標準入力に渡す）') { |v| opts[:ok_out] = v }
    o.on('--ng-out PATH', '「SSM Agent で直す」台を書き出す（backup.rb・backup_check.rb の標準入力に渡す）') { |v| opts[:ng_out] = v }
  end
  Cli.require_aws_cli
  exit SsmCheck.new(ok_out: options[:ok_out], ng_out: options[:ng_out]).run(Cli.read_ids)
end
