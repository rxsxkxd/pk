# frozen_string_literal: true

require 'json'
require_relative 'lib'

# セキュリティグループの読み書きの部品（restrict_rule.rb・swap_groups.rb・restore.rb で使う）。
# 規則は describe-security-group-rules の形（1 つの規則が 1 つの相手を持つ）で扱う。
module SecurityGroups
  SSH_PORT = 22
  GROUP_ID_PATTERN = /\Asg-[0-9a-f]{8}([0-9a-f]{9})?\z/.freeze
  DESCRIPTION = 'SSH from allowed ranges (sg-ssh-restrict)'

  module_function

  # 標準入力から、セキュリティグループの ID を 1 行に 1 つ読む（# から後と空の行は無視）
  def read_group_ids(io = $stdin)
    ids = io.each_line.map { |line| line.sub(/#.*/, '').split.first }.grep(GROUP_ID_PATTERN).uniq
    return ids unless ids.empty?

    warn 'セキュリティグループの ID がない（標準入力に 1 行 1 つで渡す）'
    exit 2
  end

  def group(group_id)
    Tools.aws('ec2', 'describe-security-groups', '--group-ids', group_id)['SecurityGroups'].first
  end

  def rules(group_id)
    filter = "Name=group-id,Values=#{group_id}"
    Tools.aws('ec2', 'describe-security-group-rules', '--filters', filter)['SecurityGroupRules']
  end

  # 受信の規則で、22 番を含むもの（すべての通信の規則や、22 番を含むポートの範囲の規則も含む）
  def covers_ssh?(rule)
    return false if rule['IsEgress']
    return true if rule['IpProtocol'] == '-1'

    rule['IpProtocol'] == 'tcp' && (rule['FromPort']..rule['ToPort']).cover?(SSH_PORT)
  end

  # 受信の規則で、22 番だけのもの
  def ssh_only?(rule)
    !rule['IsEgress'] && rule['IpProtocol'] == 'tcp' && rule['FromPort'] == SSH_PORT && rule['ToPort'] == SSH_PORT
  end

  def cidr(rule)
    rule['CidrIpv4'] || rule['CidrIpv6']
  end

  # 規則の相手（CIDR、セキュリティグループ、プレフィックスリスト）
  def source(rule)
    cidr(rule) || rule.dig('ReferencedGroupInfo', 'GroupId') || rule['PrefixListId']
  end

  def describe(rule)
    ports = rule['IpProtocol'] == '-1' ? 'すべての通信' : "#{rule['IpProtocol']} #{rule['FromPort']}-#{rule['ToPort']}"
    "#{rule['IsEgress'] ? '送信' : '受信'} #{ports}  相手 #{source(rule)}  （#{rule['SecurityGroupRuleId']}）"
  end

  # 規則を、authorize-security-group-ingress / egress の --ip-permissions の 1 つ分にする（写すとき・戻すときに使う）
  def permission(rule)
    permission = { 'IpProtocol' => rule['IpProtocol'] }
    permission.update('FromPort' => rule['FromPort'], 'ToPort' => rule['ToPort']) unless rule['IpProtocol'] == '-1'
    permission.merge(source_permission(rule))
  end

  def source_permission(rule)
    description = rule['Description'] ? { 'Description' => rule['Description'] } : {}
    return { 'IpRanges' => [{ 'CidrIp' => rule['CidrIpv4'] }.merge(description)] } if rule['CidrIpv4']
    return { 'Ipv6Ranges' => [{ 'CidrIpv6' => rule['CidrIpv6'] }.merge(description)] } if rule['CidrIpv6']
    if rule['PrefixListId']
      return { 'PrefixListIds' => [{ 'PrefixListId' => rule['PrefixListId'] }.merge(description)] }
    end

    { 'UserIdGroupPairs' => [{ 'GroupId' => rule.dig('ReferencedGroupInfo', 'GroupId') }.merge(description)] }
  end

  # 22 番を、許可する範囲の 1 つから受ける規則（IPv6 の範囲も書ける）
  def ssh_permission(cidr)
    range = if cidr.include?(':')
              { 'Ipv6Ranges' => [{ 'CidrIpv6' => cidr, 'Description' => DESCRIPTION }] }
            else
              { 'IpRanges' => [{ 'CidrIp' => cidr, 'Description' => DESCRIPTION }] }
            end
    { 'IpProtocol' => 'tcp', 'FromPort' => SSH_PORT, 'ToPort' => SSH_PORT }.merge(range)
  end

  # 規則を足して、足した規則の ID を返す
  def authorize(group_id, permissions, egress: false)
    return [] if permissions.empty?

    command = egress ? 'authorize-security-group-egress' : 'authorize-security-group-ingress'
    response = Tools.aws('ec2', command, '--group-id', group_id, '--ip-permissions', permissions.to_json)
    response['SecurityGroupRules'].map { |rule| rule['SecurityGroupRuleId'] }
  end

  def rule_ids(rules)
    rules.map { |rule| rule['SecurityGroupRuleId'] }
  end

  def revoke(group_id, rule_ids, egress: false)
    return if rule_ids.empty?

    command = egress ? 'revoke-security-group-egress' : 'revoke-security-group-ingress'
    Tools.aws('ec2', command, '--group-id', group_id, '--security-group-rule-ids', *rule_ids)
  end

  # そのグループを付けているインスタンスの ID
  def instances_using(group_id)
    interfaces = Tools.aws('ec2', 'describe-network-interfaces', '--filters', "Name=group-id,Values=#{group_id}")
    interfaces['NetworkInterfaces'].map { |eni| eni.dig('Attachment', 'InstanceId') }.compact.uniq
  end

  # そのグループを、規則の相手に指定しているグループの ID（受信・送信のどちらも。自分自身も含む）
  def referencing_groups(group_id)
    %w[ip-permission.group-id egress.ip-permission.group-id].flat_map do |filter|
      Tools.aws('ec2', 'describe-security-groups', '--filters', "Name=#{filter},Values=#{group_id}")['SecurityGroups']
           .map { |g| g['GroupId'] }
    end.uniq
  end

  # 変えた内容の記録の、既定の置き場所
  def default_record_path
    "sg-change-#{Time.now.strftime('%Y%m%d-%H%M%S')}.json"
  end

  # 変えた内容を記録する（restore.rb で元に戻すときに使う）
  def write_record(path, record)
    File.write(path, "#{JSON.pretty_generate(record)}\n")
    puts "記録: #{path}（元に戻すときは ruby rb/restore.rb #{path}）"
  end
end
