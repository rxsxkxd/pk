#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/swap_groups.rb --old-group sg-xxxx --allow-cidr 203.0.113.0/24 [--allow-cidr ...] [--record PATH] \
#     [--check-only] [--yes] < instance-ids.txt
require 'optparse'
require_relative 'new_groups'

# B. 古いセキュリティグループ（--old-group）を、22 番を除いた写しと、22 番を絞ったグループの 2 つに付け替える
# （付け替えたインスタンスだけに効く。2 つのグループの中身は new_groups.rb）。古いグループは消さない（ほかの台が使っていることがある）。
# 古いグループがほかのグループの規則の相手になっていると、外した台がその相手からの許可を失うので、止める（A を使う）。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SshGroupSwap
  def initialize(old_group:, allowed:, record:)
    @old_group = old_group
    @allowed = allowed
    @record = record
  end

  # 流れ: 古いグループの確認 → 付け替えるインスタンスの確認 → 新しいグループの用意 → 付け替え → 結果を確かめる
  def run(instance_ids, check_only: false, assume_yes: false)
    old, rules, problems = check_old_group
    targets, skipped = check_instances(instance_ids, old['VpcId'])
    code = exit_code(problems + skipped)
    return code if check_only || cannot_swap?(problems, targets)
    return 0 unless confirmed?(targets, assume_yes)

    failed = swap_all(targets, *NewGroups.prepare(old, rules, @allowed))
    verify(targets - failed)
    failed.empty? ? code : 1
  end

  # 古いグループの確認: ほかのグループの規則の相手になっていないか、22 番だけを分けられるか。[グループ, 規則, 問題の一覧]
  def check_old_group
    old = SecurityGroups.group(@old_group)
    rules = SecurityGroups.rules(@old_group)
    problems = reference_problems + range_problems(rules)
    show_old_group(old, rules, problems)
    [old, rules, problems]
  rescue Tools::AwsError => e
    warn "止めた: #{@old_group} を読めない（#{e.message}）"
    exit 2
  end

  # 付け替えるインスタンスの確認: 古いグループが付いていて、ネットワークインターフェースが 1 つの台だけ。[付け替える台, 対象外の台]
  def check_instances(instance_ids, vpc_id)
    instance_ids.partition do |id|
      instance = describe_instance(id)
      reason = instance_problem(instance, vpc_id)
      puts reason ? "対象外      #{id}  #{reason}" : "付け替える  #{id}  #{group_ids_of(instance).join(' ')}"
      reason.nil?
    end
  end

  # 付け替え: 1 台ずつ、古いグループを外して新しい 2 つを付ける（ほかのグループはそのまま）。記録を残し、失敗した台を返す
  def swap_all(ids, new_groups, created)
    before = ids.to_h { |id| [id, group_ids_of(describe_instance(id))] }
    failed = ids.reject { |id| swap(id, before[id], new_groups) }
    SecurityGroups.write_record(@record, 'kind' => 'swap_groups', 'old_group' => @old_group, 'new_groups' => new_groups,
                                         'created_groups' => created, 'instances' => before.slice(*(ids - failed)))
    failed
  end

  # 結果を確かめる: 今付いているグループを表示する
  def verify(ids)
    ids.each { |id| puts "今のグループ  #{id}  #{group_ids_of(describe_instance(id)).join(' ')}" }
    puts '今つながっている SSH はすぐには切れないことがある。新しく入り直して確かめる（締め出しても SSM なら入れる）'
  end

  private

  # 付け替えられない問題か、対象外の台があれば 1
  def exit_code(problems_and_skipped)
    problems_and_skipped.empty? ? 0 : 1
  end

  def cannot_swap?(problems, targets)
    !problems.empty? || targets.empty?
  end

  def reference_problems
    SecurityGroups.referencing_groups(@old_group).map do |group_id|
      group_id == @old_group ? '自分自身を規則の相手にしている（写すと、外した後に効かない）' : "#{group_id} の規則の相手になっている"
    end
  end

  def range_problems(rules)
    rules.select { |rule| SecurityGroups.covers_ssh?(rule) && !SecurityGroups.ssh_only?(rule) }
         .map { |rule| "22 番以外も含む規則がある（#{SecurityGroups.describe(rule)}）" }
  end

  def show_old_group(old, rules, problems)
    puts "== 古いグループ: #{@old_group}  #{old['GroupName']}（#{old['VpcId']}）"
    rules.each { |rule| puts "  #{SecurityGroups.ssh_only?(rule) ? '除く' : '写す'}: #{SecurityGroups.describe(rule)}" }
    problems.each { |problem| puts "  付け替えられない: #{problem}" }
  end

  def swap(id, before, new_groups)
    after = (before - [@old_group] + new_groups).uniq
    Tools.aws('ec2', 'modify-instance-attribute', '--instance-id', id, '--groups', *after)
    puts "付け替えた  #{id}  #{before.join(' ')} → #{after.join(' ')}"
    true
  rescue Tools::AwsError => e
    puts "失敗        #{id}  #{e.message}"
    false
  end

  def describe_instance(id)
    Tools.aws('ec2', 'describe-instances', '--instance-ids', id).dig('Reservations', 0, 'Instances', 0)
  rescue Tools::AwsError
    nil
  end

  def instance_problem(instance, vpc_id)
    return '見つからない' unless instance
    return "VPC が違う（#{instance['VpcId']}）" unless instance['VpcId'] == vpc_id
    return 'ネットワークインターフェースが複数ある（ENI ごとに手で付け替える）' if instance['NetworkInterfaces'].size > 1

    '古いグループが付いていない' unless group_ids_of(instance).include?(@old_group)
  end

  def group_ids_of(instance)
    instance['SecurityGroups'].map { |group| group['GroupId'] }
  end

  def confirmed?(targets, assume_yes)
    question = "上の「付け替える」#{targets.size} 台の #{@old_group} を、22 番を除いた写しと 22 番を絞ったグループに" \
               '付け替えますか？（新しいグループがなければ作る）'
    return true if assume_yes || Tools.ask(question)

    puts '中止した'
    false
  end
end

def parse_options
  options = { allowed: [], record: SecurityGroups.default_record_path }
  OptionParser.new do |o|
    o.on('--old-group GROUP_ID', '外すセキュリティグループ') { |v| options[:old_group] = v }
    o.on('--allow-cidr CIDR', '22 番を許可する範囲（何度でも指定できる）') { |v| options[:allowed] << v }
    o.on('--record PATH', '変えた内容の記録（restore.rb で元に戻すときに使う）') { |v| options[:record] = v }
    o.on('--check-only') { options[:check_only] = true }
    o.on('--yes') { options[:yes] = true }
  end.parse!
  options
end

options = parse_options
abort '--old-group と --allow-cidr が要る' if options[:old_group].nil? || options[:allowed].empty?
swap = SshGroupSwap.new(old_group: options[:old_group], allowed: options[:allowed].uniq, record: options[:record])
exit swap.run(Tools.read_ids, check_only: options[:check_only], assume_yes: options[:yes])
