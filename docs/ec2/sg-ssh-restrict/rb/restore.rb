#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/restore.rb sg-change-20261101-120000.json [--yes]
require 'json'
require 'optparse'
require_relative 'security_groups'

# restrict_rule.rb・swap_groups.rb の記録から、元に戻す。
#   restrict_rule: 消した規則を足し直してから、足した規則を消す（元の相手が途切れないように）
#   swap_groups: 付け替えたインスタンスのグループを、元の一覧に戻す（作ったグループは消さない。消し方を表示する）
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SgRestore
  def initialize(record)
    @record = record
  end

  # 流れ: 記録を表示する → 試行するかを確かめる → 元に戻す
  def run(assume_yes: false)
    show_record
    return 0 unless confirmed?(assume_yes)

    problems = @record['kind'] == 'restrict_rule' ? restore_rules : restore_groups
    problems.empty? ? 0 : 1
  end

  def show_record
    if @record['kind'] == 'restrict_rule'
      @record['changes'].each { |change| show_rule_change(change) }
    else
      @record['instances'].each { |id, groups| puts "戻す  #{id}  → #{groups.join(' ')}" }
    end
  end

  # restrict_rule の記録から戻す。問題の一覧を返す
  def restore_rules
    @record['changes'].map do |change|
      group_id = change['group_id']
      SecurityGroups.authorize(group_id, change['revoked_rules'].map { |rule| SecurityGroups.permission(rule) })
      SecurityGroups.revoke(group_id, change['added_rule_ids'])
      puts "戻した  #{group_id}"
      nil
    rescue Tools::AwsError => e
      puts "失敗    #{group_id}  #{e.message}"
      e.message
    end.compact
  end

  # swap_groups の記録から戻す。問題の一覧を返す
  def restore_groups
    problems = @record['instances'].map do |id, groups|
      Tools.aws('ec2', 'modify-instance-attribute', '--instance-id', id, '--groups', *groups)
      puts "戻した  #{id}  #{groups.join(' ')}"
      nil
    rescue Tools::AwsError => e
      puts "失敗    #{id}  #{e.message}"
      e.message
    end.compact
    print_created_groups
    problems
  end

  private

  def show_rule_change(change)
    puts "== #{change['group_id']}  足し直す #{change['revoked_rules'].size} 件、消す #{change['added_rule_ids'].size} 件"
    change['revoked_rules'].each { |rule| puts "  足し直す: #{SecurityGroups.describe(rule)}" }
  end

  def print_created_groups
    return if @record['created_groups'].empty?

    puts '作ったグループは消していない。ほかの台が使っていなければ、次で消せる:'
    @record['created_groups'].each { |group_id| puts "  aws ec2 delete-security-group --group-id #{group_id}" }
  end

  def confirmed?(assume_yes)
    return true if assume_yes || Tools.ask('上の内容で元に戻しますか？')

    puts '中止した'
    false
  end
end

assume_yes = false
OptionParser.new { |o| o.on('--yes') { assume_yes = true } }.parse!
abort '記録のファイルを指定する（ruby rb/restore.rb sg-change-....json）' if ARGV.empty?
exit SgRestore.new(JSON.parse(File.read(ARGV.first))).run(assume_yes: assume_yes)
