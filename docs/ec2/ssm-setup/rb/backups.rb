# frozen_string_literal: true

require 'time'
require_relative 'ssm_setup'

# SSM Agent の導入の前のバックアップ（AMI）の決まりと確認。
# rb/backup.rb で作った AMI には、Purpose（ssm-setup-backup）・SourceInstanceId・BackupLabel のタグが付く。
# rb/backup_check.rb は、インスタンスごとに次の 3 つがそろった AMI があるかを確かめる。
# - BackupLabel のタグが、指定した値と一致する
# - 作成が終わっている（State が available。AMI の作成は非同期で進むため）
# - 作成の時刻が、確かめた時点から 12 時間以内
# ほかの作業のバックアップ（port-guard-rollout-backup・al2-update-backup）とは、タグ Purpose で分けて混ぜない。
module Backups
  PURPOSE = 'ssm-setup-backup'
  LABEL_TAG = 'BackupLabel'
  MAX_AGE_HOURS = 12
  LABEL_PATTERN = %r{\A[A-Za-z0-9 _.:/=+@-]{1,128}\z}.freeze
  LABEL_RULE = '英数字と空白・_ . : / = + @ - だけで、128 文字まで（例 2026-11、2026-11-12）'
  # AMI の名前に使えない文字の並び（1 つの "-" に置き換える）と、名前の長さの上限
  AMI_NAME_DISALLOWED = %r{[^A-Za-z0-9()\[\]./'@_-]+}.freeze
  AMI_NAME_MAX_LENGTH = 128

  # 条件に合う AMI を探した結果（ok なら image_id と created に、合うものの値。そうでなければ reason に理由）
  Found = Struct.new(:ok, :image_id, :created, :reason, keyword_init: true)

  module_function

  # rb/backup.rb・rb/backup_check.rb で共通の --backup-label
  def define_label_option(parser, options)
    parser.on('--backup-label LABEL', 'バックアップ作業のタイミング（例 2026-11）。AMI のタグ BackupLabel の値') do |value|
      options[:label] = value
    end
  end

  # --backup-label の値が正しくなければ、終了コード 2 で止める
  def require_label(label)
    SsmSetup.usage_error("--backup-label が要る（#{LABEL_RULE}）") unless LABEL_PATTERN.match?(label.to_s)
  end

  # 条件に合う AMI を探す。合うものがなければ、理由をつけて返す
  def find(id, label)
    choose(tagged_images(id, label).sort_by { |image| image['CreationDate'] }.reverse, label)
  rescue Tools::AwsError => e
    Found.new(ok: false, reason: "バックアップを確かめられない（#{e.summary}）")
  end

  # 見つかった AMI の説明（AMI の ID、作成の時刻、経過時間、期限までの残り）
  def describe(found)
    age = age_hours(found.created)
    format('%<image>s  作成 %<created>s（%<age>.1f 時間前。期限まであと %<left>.1f 時間）',
           image: found.image_id, created: found.created, age: age, left: MAX_AGE_HOURS - age)
  end

  # AMI の名前: <Name タグ>-<インスタンスの ID>-before-ssm-setup-<実行の ID>。
  # 使えない文字は "-" に置き換え、長すぎるときは先頭（Name タグの側）を削る
  def image_name(instance_id, instance_name, run_id)
    label = instance_name.to_s.gsub(AMI_NAME_DISALLOWED, '-').gsub(/\A-+|-+\z/, '')
    name = [label, instance_id, 'before-ssm-setup', run_id].reject(&:empty?).join('-')
    name[-[AMI_NAME_MAX_LENGTH, name.size].min..].sub(/\A-+/, '')
  end

  # AMI とスナップショットに付けるタグ（create-image の --tag-specifications の形）
  def tag_specifications(tags)
    list = { 'Purpose' => PURPOSE }.merge(tags).map { |key, value| { 'Key' => key, 'Value' => value.to_s } }
    %w[image snapshot].map { |type| { 'ResourceType' => type, 'Tags' => list } }
  end

  def age_hours(created)
    (Time.now - Time.iso8601(created)) / 3600
  end

  # 新しいものから順に並べた AMI から、条件に合うものを選ぶ
  def choose(images, label)
    return Found.new(ok: false, reason: "「#{label}」のバックアップ（AMI）がない") if images.empty?

    recent = within_max_age(images)
    return too_old(images.first, label) if recent.empty?

    usable = recent.find { |image| image['State'] == 'available' }
    return not_available(recent.first) unless usable

    Found.new(ok: true, image_id: usable['ImageId'], created: usable['CreationDate'])
  end

  def within_max_age(images)
    images.select { |image| age_hours(image['CreationDate']) <= MAX_AGE_HOURS }
  end

  def tagged_images(id, label)
    Tools.aws('ec2', 'describe-images', '--owners', 'self', '--filters',
              "Name=tag:Purpose,Values=#{PURPOSE}", "Name=tag:SourceInstanceId,Values=#{id}",
              "Name=tag:#{LABEL_TAG},Values=#{label}")['Images']
  end

  def too_old(newest, label)
    Found.new(ok: false, image_id: newest['ImageId'], created: newest['CreationDate'],
              reason: "「#{label}」のバックアップが #{MAX_AGE_HOURS} 時間より前のものしかない" \
                      "（最新 #{newest['ImageId']}、作成 #{newest['CreationDate']}）")
  end

  def not_available(newest)
    state = newest['State']
    reason = if state == 'pending'
               "バックアップ（#{newest['ImageId']}）がまだ作成中（pending）"
             else
               "バックアップ（#{newest['ImageId']}）が使えない状態（#{state}）"
             end
    Found.new(ok: false, image_id: newest['ImageId'], created: newest['CreationDate'], reason: reason)
  end

  private_class_method :age_hours, :choose, :within_max_age, :tagged_images, :too_old, :not_available
end
