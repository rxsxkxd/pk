#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/backup_check.rb --backup-label 2026-11 < ok.txt
require 'optparse'
require_relative 'al2_update'
require_relative 'backups'

# バックアップがあるかを確かめるだけ（読み取りだけ。何も変えない）。
# rb/update.rb が更新の前に行う確認（UpdateBackups.find）と同じ条件で、「更新できる」と「更新できない（理由つき）」に分ける。
# rb/backup.rb で AMI の作成を始めた後、作成が終わったかを確かめるのにも使う。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class UpdateBackupCheck
  def initialize(label:)
    @label = label
  end

  # 流れ: 1 台ずつ確かめて表示する → 結果を表示する
  def run(ids)
    puts "== #{ids.size} 台のバックアップを確かめる（バックアップ作業のタイミング: #{@label}。読み取りだけ）"
    found = UpdateBackups.check_all(ids, @label)
    print_summary(found)
    found.values.all?(&:ok) ? 0 : 1
  end

  def print_summary(found)
    ok = found.values.count(&:ok)
    puts "== 結果: 更新できる（条件に合うバックアップがある） #{ok} 台、更新できない #{found.size - ok} 台"
  end
end

def parse_options
  options = {}
  OptionParser.new do |o|
    UpdateBackups.define_label_option(o, options)
  end.parse!
  options
rescue OptionParser::ParseError => e
  AL2Update.usage_error(e.message)
end

options = parse_options
UpdateBackups.require_label(options[:label])
AL2Update.require_aws_cli
exit UpdateBackupCheck.new(label: options[:label]).run(Tools.read_ids)
