# frozen_string_literal: true

require_relative 'ssm_setup'

# rb/ssm_check.rb で確かめる 1 台の状態（権限と AWS の上の状態だけ。インスタンスには何も送らない）。
# インスタンス → インスタンスプロファイルとロール → ロールの AmazonSSMManagedInstanceCore（参考）→ SSM の登録 の順に読み、
# SSM 有効・SSM Agent で直す・手で直す のどれかに分ける。公開のメソッドが流れの大枠、private の下がヘルパ。
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
    @policy.start_with?("#{SsmSetup::CORE_POLICY} が付いていない")
  end

  # 表示の行（1 行目がインスタンス、2 行目から詳細）
  def lines
    ["#{@id}  #{@name}  #{@state}"] + detail_lines.map { |line| "    #{line}" }
  end

  private

  # 読めたら true。見つからない・読めないなら、理由を problems に入れて false
  def read_instance
    instance = SsmSetup.find_instance(@id)
    @problems << 'インスタンスが見つからない' unless instance
    return false unless instance

    @name = SsmSetup.instance_name(instance)
    @state = SsmSetup.instance_state(instance)
    true
  rescue Tools::AwsError => e
    @problems << "情報を取れない（#{e.summary}）"
    false
  end

  def read_profile
    @profile = SsmSetup.associated_profiles([@id])[@id].to_s.split('/').last.to_s # パスがあっても最後の部分が名前
    return @policy = 'インスタンスプロファイルがない' if @profile.empty?

    @roles = SsmSetup.profile_roles(@profile)
    @policy = 'インスタンスプロファイルにロールが入っていない' if @roles.empty?
  rescue Tools::AwsError => e
    @policy = "確かめられない（インスタンスプロファイルを読めない: #{e.summary}）"
  end

  def describe_policy(role)
    policies = SsmSetup.attached_policies(role)
    return "#{SsmSetup::CORE_POLICY} が付いている" if SsmSetup.core_policy?(policies)

    inline = Tools.aws('iam', 'list-role-policies', '--role-name', role)['PolicyNames']
    "#{SsmSetup::CORE_POLICY} が付いていない（要確認。付いているもの: #{join_or_none(policies.map(&:first))}、" \
      "インライン: #{join_or_none(inline)}）"
  rescue Tools::AwsError => e
    "確かめられない（ロールのポリシーを読めない: #{e.summary}）"
  end

  def read_registration
    information = SsmSetup.instance_information(@id)
    @ping_status = information ? information['PingStatus'] : '未登録'
    @agent_version = information && information['AgentVersion']
  rescue Tools::AwsError => e
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

    "ロールに #{SsmSetup::CORE_POLICY} が付いていない（すでにあるロールなら、手で足すかを決める。" \
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
