#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/backup_check.rb --backup-label 2026-11 [--ok-out backup-ok.txt] < ng.txt
require 'optparse'
require_relative 'backups'

# バックアップがあるかを確かめるだけ（読み取りだけ。何も変えない）。
# 「操作できる（条件に合うバックアップがある）」と「操作できない（理由つき）」に分けて表示する。
# --ok-out で操作できる台だけの一覧を書き出す。SSM Agent の導入（instance/agent-install.sh）は、この一覧の台にだけ流す。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class BackupCheck
  def initialize(label, ok_out: nil)
    @label = label
    @ok_out = ok_out
  end

  # 流れ: 1 台ずつ確かめて表示する → 結果を表示する → 一覧を書き出す
  def run(ids)
    puts "#{ids.size} 台のバックアップを確かめる（バックアップ作業のタイミング: #{@label}。読み取りだけ）"
    found = ids.to_h { |id| [id, Backups.find(id, @label)] }
    usable, missing = ids.partition { |id| found[id].ok }
    print_result(found, usable, missing)
    write_ok_list(usable) if @ok_out
    missing.empty? ? 0 : 1
  end

  private

  def print_result(found, usable, missing)
    print_group("操作できる（条件に合うバックアップがある。#{usable.size} 台）",
                usable.map { |id| "#{id}  #{Backups.describe(found[id])}" })
    print_group("操作できない（#{missing.size} 台）", missing.map { |id| "#{id}  理由: #{found[id].reason}" })
    puts "\n== 結果: 操作できる #{usable.size} 台、操作できない #{missing.size} 台"
  end

  def print_group(title, lines)
    puts "\n== #{title}"
    lines.each { |line| puts "  #{line}" }
  end

  def write_ok_list(usable)
    SsmSetup.write_list(@ok_out, "backup_check.rb でバックアップ（#{@label}）がそろった台（SSM Agent の導入は、この台にだけ流す）",
                        usable)
    puts "操作できる台の一覧を書き出した: #{@ok_out}（#{usable.size} 台）"
  end
end

if $PROGRAM_NAME == __FILE__
  options = SsmSetup.parse_options do |o, opts|
    Backups.define_label_option(o, opts)
    o.on('--ok-out PATH', '操作できる台（バックアップがそろった台）を書き出す') { |v| opts[:ok_out] = v }
  end
  Backups.require_label(options[:label])
  SsmSetup.require_aws_cli
  exit BackupCheck.new(options[:label], ok_out: options[:ok_out]).run(Tools.read_ids)
end
