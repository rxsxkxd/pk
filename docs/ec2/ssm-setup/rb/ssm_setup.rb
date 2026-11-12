# frozen_string_literal: true

require_relative 'lib'

# ssm-setup の rb/ の道具で共用する部品（このフェーズのもの）。
# 使い方の誤りの扱い、共通のオプション、インスタンス・ロール・SSM の登録の読み方。
module SsmSetup
  CORE_POLICY = 'AmazonSSMManagedInstanceCore'
  NOT_FOUND = %w[InvalidInstanceID.NotFound InvalidInstanceID.Malformed].freeze

  module_function

  # 入力・前提の問題: 理由を出して、終了コード 2 で止める
  def usage_error(message)
    warn message
    exit 2
  end

  def require_aws_cli
    usage_error('aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）') unless Tools.command?('aws')
  end

  # OptionParser でオプションを読む（ブロックでオプションを定義する）。誤りなら終了コード 2
  def parse_options(options = {})
    OptionParser.new { |parser| yield parser, options }.parse!
    options
  rescue OptionParser::ParseError => e
    usage_error(e.message)
  end

  # インスタンスを操作するコマンドの --check-only・--yes（action は、行うことの説明）
  def define_run_options(parser, options, action)
    parser.on('--check-only', "確かめて表示するだけ（#{action}は行わない）") { options[:check_only] = true }
    parser.on('--yes', "#{action}を試行するかを確かめずに進める") { options[:yes] = true }
  end

  # 一覧を書き出す（1 行目は説明の # の行）
  def write_list(path, header, lines)
    File.write(path, (["# #{header}"] + lines).map { |line| "#{line}\n" }.join)
  end

  # インスタンスの情報（describe-instances の 1 台分）。見つからなければ nil。ほかの失敗は AwsError
  def find_instance(id)
    Tools.aws('ec2', 'describe-instances', '--instance-ids', id).dig('Reservations', 0, 'Instances', 0)
  rescue Tools::AwsError => e
    raise unless NOT_FOUND.include?(e.code)

    nil
  end

  def instance_name(instance)
    (instance['Tags'] || []).find { |tag| tag['Key'] == 'Name' }&.fetch('Value').to_s
  end

  def instance_state(instance)
    instance.dig('State', 'Name').to_s
  end

  # SSM の登録の情報（describe-instance-information の 1 台分）。なければ nil
  def instance_information(id)
    Tools.aws('ssm', 'describe-instance-information', '--filters',
              "Key=InstanceIds,Values=#{id}")['InstanceInformationList'][0]
  end

  # インスタンスの ID → 関連付けられているインスタンスプロファイルの ARN（関連付けがない台は入らない）
  def associated_profiles(ids)
    ids.each_slice(200).with_object({}) do |slice, result| # フィルターの値は 200 個まで
      Tools.aws('ec2', 'describe-iam-instance-profile-associations', '--filters',
                "Name=instance-id,Values=#{slice.join(',')}")['IamInstanceProfileAssociations'].each do |association|
        next unless %w[associating associated].include?(association['State'])

        result[association['InstanceId']] = association.dig('IamInstanceProfile', 'Arn')
      end
    end
  end

  # インスタンスプロファイルの中のロールの名前の一覧
  def profile_roles(profile_name)
    Tools.aws('iam', 'get-instance-profile', '--instance-profile-name',
              profile_name).dig('InstanceProfile', 'Roles').map { |role| role['RoleName'] }
  end

  # ロールに付いている管理ポリシー（[名前, ARN] の一覧）
  def attached_policies(role)
    Tools.aws('iam', 'list-attached-role-policies', '--role-name', role)['AttachedPolicies']
         .map { |policy| [policy['PolicyName'], policy['PolicyArn']] }
  end

  def core_policy?(policies)
    policies.any? { |_, arn| arn.end_with?(":policy/#{CORE_POLICY}") }
  end
end
