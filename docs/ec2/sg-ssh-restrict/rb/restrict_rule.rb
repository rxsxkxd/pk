#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/restrict_rule.rb --allow-cidr 203.0.113.0/24 [--allow-cidr ...] [--record PATH] [--check-only] [--yes] \
#     < group-ids.txt
require 'optparse'
require_relative 'security_groups'

# 1 つのグループの、22 番の規則をどうするか
SshPlan = Struct.new(:group_id, :name, :instances, :add, :revoke, :keep, :manual, keyword_init: true) do
  def changes?
    !(add.empty? && revoke.empty?)
  end
end

# A. 今のセキュリティグループの 22 番の規則を、許可する範囲（--allow-cidr）に絞る。
# そのグループを付けた全部のインスタンスに、すぐ効く。許可する範囲の規則を足してから、ほかの範囲の 22 番の規則を消す
# （許可する相手が途切れないように）。相手がセキュリティグループ・プレフィックスリストの規則は、すでに絞られているので残す。
# 22 番を含むポートの範囲の規則（すべての通信など）は、22 番だけを絞れないので、手で直す。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SshRuleRestrict
  def initialize(allowed:, record:)
    @allowed = allowed
    @record = record
  end

  # 流れ: 22 番の規則を調べて表示する → 許可する範囲を足してから、ほかの範囲を消す → 結果を確かめる
  def run(group_ids, check_only: false, assume_yes: false)
    plans = inspect_groups(group_ids)
    todo = plans.select(&:changes?)
    return exit_code(plans) if check_only || todo.empty?
    return 0 unless confirmed?(todo, assume_yes)

    all_done = restrict_all(todo)
    verify(todo.map(&:group_id))
    all_done ? exit_code(plans) : 1
  end

  # 22 番の規則を調べて表示する（影響は、そのグループを付けている台すべてに及ぶ）
  def inspect_groups(group_ids)
    group_ids.map do |group_id|
      plan = inspect_group(group_id)
      show_plan(plan)
      plan
    end
  end

  # 許可する範囲を足してから、ほかの範囲を消す。変えた内容を記録し、すべて済んだかを返す
  def restrict_all(plans)
    changes = plans.map { |plan| restrict(plan) }
    SecurityGroups.write_record(@record, 'kind' => 'restrict_rule', 'changes' => changes)
    changes.none? { |change| change['error'] }
  end

  # 結果を確かめる: 今の 22 番の規則を表示する
  def verify(group_ids)
    group_ids.each do |group_id|
      puts "== 今の 22 番の規則: #{group_id}"
      SecurityGroups.rules(group_id).select { |rule| SecurityGroups.covers_ssh?(rule) }
                    .each { |rule| puts "  #{SecurityGroups.describe(rule)}" }
    end
    puts '今つながっている SSH はすぐには切れないことがある。新しく入り直して確かめる（締め出しても SSM なら入れる）'
  end

  private

  def inspect_group(group_id)
    ssh_rules = SecurityGroups.rules(group_id).select { |rule| SecurityGroups.covers_ssh?(rule) }
    SshPlan.new(group_id: group_id, name: SecurityGroups.group(group_id)['GroupName'],
                instances: SecurityGroups.instances_using(group_id), **split_rules(ssh_rules))
  rescue Tools::AwsError => e
    warn "止めた: #{group_id} を読めない（#{e.message}）"
    exit 2
  end

  # 22 番の規則を、足す範囲・消す規則・残す規則・手で直す規則に分ける
  def split_rules(ssh_rules)
    manual, ssh_only = ssh_rules.partition { |rule| !SecurityGroups.ssh_only?(rule) }
    cidr_rules, referenced = ssh_only.partition { |rule| SecurityGroups.cidr(rule) }
    revoke = cidr_rules.reject { |rule| allowed?(rule) }
    { add: @allowed - cidr_rules.map { |rule| SecurityGroups.cidr(rule) }, revoke: revoke,
      keep: (cidr_rules - revoke) + referenced, manual: manual }
  end

  def allowed?(rule)
    @allowed.include?(SecurityGroups.cidr(rule))
  end

  def show_plan(plan)
    puts "== #{plan.group_id}  #{plan.name}  （付けているインスタンス #{instances_label(plan)}）"
    plan.add.each { |cidr| puts "  足す: 受信 tcp 22-22  相手 #{cidr}" }
    labeled_rules(plan).each { |label, rule| puts "  #{label}: #{SecurityGroups.describe(rule)}" }
    puts '  （手で直す規則は、22 番以外も含むので、22 番だけを絞れない）' unless plan.manual.empty?
  end

  def instances_label(plan)
    "#{plan.instances.size} 台: #{plan.instances.join(' ')}"
  end

  def labeled_rules(plan)
    { '消す' => plan.revoke, 'そのまま' => plan.keep, '手で直す' => plan.manual }
      .flat_map { |label, rules| rules.map { |rule| [label, rule] } }
  end

  # 足せなければ、消さない（許可する相手が途切れないように）
  def restrict(plan)
    change = { 'group_id' => plan.group_id, 'added_rule_ids' => [], 'revoked_rules' => [] }
    change['added_rule_ids'] = add_allowed(plan)
    SecurityGroups.revoke(plan.group_id, SecurityGroups.rule_ids(plan.revoke))
    change['revoked_rules'] = plan.revoke
    puts "直した  #{plan.group_id}"
    change
  rescue Tools::AwsError => e
    puts "失敗    #{plan.group_id}  #{e.message}"
    change.merge('error' => e.message)
  end

  def add_allowed(plan)
    SecurityGroups.authorize(plan.group_id, plan.add.map { |cidr| SecurityGroups.ssh_permission(cidr) })
  end

  # 手で直す規則が残っていれば 1
  def exit_code(plans)
    plans.all? { |plan| plan.manual.empty? } ? 0 : 1
  end

  def confirmed?(todo, assume_yes)
    count = todo.sum { |plan| plan.instances.size }
    question = "上の #{todo.size} 個のグループの 22 番の規則を直しますか？（付けているインスタンス #{count} 台に、すぐ効く）"
    return true if assume_yes || Tools.ask(question)

    puts '中止した'
    false
  end
end

def parse_options
  options = { allowed: [], record: SecurityGroups.default_record_path }
  OptionParser.new do |o|
    o.on('--allow-cidr CIDR', '22 番を許可する範囲（何度でも指定できる）') { |v| options[:allowed] << v }
    o.on('--record PATH', '変えた内容の記録（restore.rb で元に戻すときに使う）') { |v| options[:record] = v }
    o.on('--check-only') { options[:check_only] = true }
    o.on('--yes') { options[:yes] = true }
  end.parse!
  options
end

options = parse_options
abort '--allow-cidr が要る（22 番を許可する範囲）' if options[:allowed].empty?
restrict = SshRuleRestrict.new(allowed: options[:allowed].uniq, record: options[:record])
exit restrict.run(SecurityGroups.read_group_ids, check_only: options[:check_only], assume_yes: options[:yes])
