# frozen_string_literal: true

require 'json'
require_relative 'security_groups'

# swap_groups.rb が付け替える先の、2 つのセキュリティグループを用意する（同じ名前があれば使い、なければ作る）。
#   <古い名前>-no-ssh: 古いグループの規則から、受信の 22 番だけの規則を除いた写し（送信の規則も写す）
#   <古い名前>-ssh-limited: 22 番を、許可する範囲からだけ受ける（送信の規則は持たない。送信は写しの規則だけが効く）
module NewGroups
  NO_SSH_SUFFIX = '-no-ssh'
  SSH_SUFFIX = '-ssh-limited'

  module_function

  # [[22 番を除いた写し, 22 番を絞ったもの], 作ったグループ] を返す
  def prepare(old, rules, allowed)
    no_ssh = find("#{old['GroupName']}#{NO_SSH_SUFFIX}", old['VpcId'])
    ssh = find("#{old['GroupName']}#{SSH_SUFFIX}", old['VpcId'])
    created = []
    created << (no_ssh = create_copy_without_ssh(old, rules)) unless no_ssh
    created << (ssh = create_ssh_limited(old, allowed)) unless ssh
    [[no_ssh, ssh], created]
  end

  def find(name, vpc_id)
    filters = ["Name=group-name,Values=#{name}", "Name=vpc-id,Values=#{vpc_id}"]
    groups = Tools.aws('ec2', 'describe-security-groups', '--filters', *filters)['SecurityGroups']
    group_id = groups.first&.fetch('GroupId')
    puts "あるものを使う  #{group_id}  #{name}（中身は変えない）" if group_id
    group_id
  end

  def create_copy_without_ssh(old, rules)
    group_id = create("#{old['GroupName']}#{NO_SSH_SUFFIX}", "Copy of #{old['GroupId']} without SSH", old['VpcId'])
    copy_rules(group_id, rules.reject { |rule| SecurityGroups.ssh_only?(rule) })
    group_id
  end

  # 規則を写す（送信の規則は、既定のすべて許可を消してから写す）
  def copy_rules(group_id, rules)
    ingress, egress = rules.partition { |rule| !rule['IsEgress'] }
    SecurityGroups.authorize(group_id, ingress.map { |rule| SecurityGroups.permission(rule) })
    revoke_default_egress(group_id)
    SecurityGroups.authorize(group_id, egress.map { |rule| SecurityGroups.permission(rule) }, egress: true)
  end

  def create_ssh_limited(old, allowed)
    description = "SSH from allowed ranges (for #{old['GroupId']})"
    group_id = create("#{old['GroupName']}#{SSH_SUFFIX}", description, old['VpcId'])
    SecurityGroups.authorize(group_id, allowed.map { |cidr| SecurityGroups.ssh_permission(cidr) })
    revoke_default_egress(group_id)
    group_id
  end

  def create(name, description, vpc_id)
    tags = [{ 'ResourceType' => 'security-group',
              'Tags' => [{ 'Key' => 'Name', 'Value' => name }, { 'Key' => 'Purpose', 'Value' => 'sg-ssh-restrict' }] }]
    group_id = Tools.aws('ec2', 'create-security-group', '--group-name', name, '--description', description,
                         '--vpc-id', vpc_id, '--tag-specifications', tags.to_json)['GroupId']
    puts "作った          #{group_id}  #{name}"
    group_id
  end

  # 作ったばかりのグループの、既定の送信の規則（すべて許可）を消す
  def revoke_default_egress(group_id)
    egress = SecurityGroups.rules(group_id).select { |rule| rule['IsEgress'] }
    SecurityGroups.revoke(group_id, SecurityGroups.rule_ids(egress), egress: true)
  end
end
