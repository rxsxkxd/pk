#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/backup_check.rb --backup-label 2026-11 [--ok-out backup-ok.txt] < ng.txt
require 'time'
require_relative 'lib/cli'

# バックアップがあるかを確かめるだけ（読み取りだけ。何も変えない）。
# インスタンスごとに、rb/backup.rb で作った AMI のうち、次の 3 つがそろったものがあるかを確かめる。
# - タグ Purpose が ssm-setup-backup、SourceInstanceId がそのインスタンス、BackupLabel が指定した値
# - 作成が終わっている（State が available。AMI の作成は非同期で進むため）
# - 作成の時刻が、確かめた時点から 12 時間以内
# 「操作できる」と「操作できない（理由つき）」に分けて表示し、--ok-out で操作できる台だけの一覧を書き出す。
# SSM Agent の導入（command/instance/agent-install.sh）は、この一覧の台にだけ流す。
# タグの決まりは rb/backup.rb と同じ（AWS の機能の仕様に紐づくので、lib/ に置かず、両方に書いている）。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class BackupCheck
  PURPOSE = 'ssm-setup-backup'
  LABEL_TAG = 'BackupLabel'
  LABEL_PATTERN = %r{\A[A-Za-z0-9 _.:/=+@-]{1,128}\z}.freeze
  LABEL_RULE = '英数字と空白・_ . : / = + @ - だけで、128 文字まで（例 2026-11、2026-11-12）'
  MAX_AGE_HOURS = 12

  # 条件に合う AMI を探した結果（ok なら image_id と created に、合うものの値。そうでなければ reason に理由）
  Found = Struct.new(:ok, :image_id, :created, :reason, keyword_init: true)

  def initialize(label, ok_out: nil)
    @label = label
    @ok_out = ok_out
  end

  # 流れ: 1 台ずつ確かめて表示する → 結果を表示する → 一覧を書き出す
  def run(ids)
    puts "#{ids.size} 台のバックアップを確かめる（バックアップ作業のタイミング: #{@label}。読み取りだけ）"
    found = ids.to_h { |id| [id, find(id)] }
    usable, missing = ids.partition { |id| found[id].ok }
    print_result(found, usable, missing)
    write_ok_list(usable) if @ok_out
    missing.empty? ? 0 : 1
  end

  # 条件に合う AMI を探す。合うものがなければ、理由をつけて返す
  def find(id)
    choose(tagged_images(id).sort_by { |image| image['CreationDate'] }.reverse)
  rescue AwsCli::Error => e
    Found.new(ok: false, reason: "バックアップを確かめられない（#{e.summary}）")
  end

  private

  def tagged_images(id)
    AwsCli.run('ec2', 'describe-images', '--owners', 'self', '--filters',
               "Name=tag:Purpose,Values=#{PURPOSE}", "Name=tag:SourceInstanceId,Values=#{id}",
               "Name=tag:#{LABEL_TAG},Values=#{@label}")['Images']
  end

  # 新しいものから順に並べた AMI から、条件に合うものを選ぶ
  def choose(images)
    return Found.new(ok: false, reason: "「#{@label}」のバックアップ（AMI）がない") if images.empty?

    recent = within_max_age(images)
    return too_old(images.first) if recent.empty?

    usable = recent.find { |image| image['State'] == 'available' }
    return not_available(recent.first) unless usable

    Found.new(ok: true, image_id: usable['ImageId'], created: usable['CreationDate'])
  end

  def within_max_age(images)
    images.select { |image| age_hours(image['CreationDate']) <= MAX_AGE_HOURS }
  end

  def age_hours(created)
    (Time.now - Time.iso8601(created)) / 3600
  end

  def too_old(newest)
    Found.new(ok: false, reason: "「#{@label}」のバックアップが #{MAX_AGE_HOURS} 時間より前のものしかない" \
                                 "（最新 #{newest['ImageId']}、作成 #{newest['CreationDate']}）")
  end

  def not_available(newest)
    state = newest['State']
    reason = if state == 'pending'
               "バックアップ（#{newest['ImageId']}）がまだ作成中（pending）"
             else
               "バックアップ（#{newest['ImageId']}）が使えない状態（#{state}）"
             end
    Found.new(ok: false, reason: reason)
  end

  # 見つかった AMI の説明（AMI の ID、作成の時刻、経過時間、期限までの残り）
  def describe(found)
    age = age_hours(found.created)
    format('%<image>s  作成 %<created>s（%<age>.1f 時間前。期限まであと %<left>.1f 時間）',
           image: found.image_id, created: found.created, age: age, left: MAX_AGE_HOURS - age)
  end

  def print_result(found, usable, missing)
    print_group("操作できる（条件に合うバックアップがある。#{usable.size} 台）", usable.map { |id| "#{id}  #{describe(found[id])}" })
    print_group("操作できない（#{missing.size} 台）", missing.map { |id| "#{id}  理由: #{found[id].reason}" })
    puts "\n== 結果: 操作できる #{usable.size} 台、操作できない #{missing.size} 台"
  end

  def print_group(title, lines)
    puts "\n== #{title}"
    lines.each { |line| puts "  #{line}" }
  end

  def write_ok_list(usable)
    Cli.write_list(@ok_out, "backup_check.rb でバックアップ（#{@label}）がそろった台（SSM Agent の導入は、この台にだけ流す）", usable)
    puts "操作できる台の一覧を書き出した: #{@ok_out}（#{usable.size} 台）"
  end
end

if $PROGRAM_NAME == __FILE__
  options = Cli.parse_options do |o, opts|
    o.on('--backup-label LABEL', 'バックアップ作業のタイミング（rb/backup.rb で指定した値）') { |v| opts[:label] = v }
    o.on('--ok-out PATH', '操作できる台（バックアップがそろった台）を書き出す') { |v| opts[:ok_out] = v }
  end
  unless BackupCheck::LABEL_PATTERN.match?(options[:label].to_s)
    Cli.usage_error("--backup-label が要る（#{BackupCheck::LABEL_RULE}）")
  end
  Cli.require_aws_cli
  exit BackupCheck.new(options[:label], ok_out: options[:ok_out]).run(Cli.read_ids)
end
