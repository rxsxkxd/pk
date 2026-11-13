#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/backup.rb --backup-label 2026-11 [--check-only] [--yes] < ng.txt
require 'json'
require_relative 'lib/flow'

# SSM Agent の導入の前のバックアップ: インスタンスごとに AMI を作る（create-image --no-reboot。再起動しない。完了は待たない）。
# 確かめる: 1 台ずつ、状態・ルートボリュームの種類・AMI を作る権限を確かめる。
# 行う: 1 台ずつ AMI の作成を始める。作り終わったかは rb/backup_check.rb で確かめる。
# AMI とスナップショットには、Purpose（ssm-setup-backup）・SourceInstanceId・BackupLabel などのタグを付ける
# （rb/backup_check.rb は同じタグで探す。AWS の機能の仕様に紐づくので、決まりは lib/ に置かず、両方に書いている）。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class Backup
  PURPOSE = 'ssm-setup-backup'
  LABEL_TAG = 'BackupLabel'
  LABEL_PATTERN = %r{\A[A-Za-z0-9 _.:/=+@-]{1,128}\z}.freeze
  LABEL_RULE = '英数字と空白・_ . : / = + @ - だけで、128 文字まで（例 2026-11、2026-11-12）'
  MAX_AGE_HOURS = 12 # rb/backup_check.rb が使えるとみなす期限（案内の表示だけに使う）
  BACKUP_STATES = %w[running stopped].freeze
  NOT_FOUND = %w[InvalidInstanceID.NotFound InvalidInstanceID.Malformed].freeze
  # AMI の名前に使えない文字の並び（1 つの "-" に置き換える）と、名前の長さの上限
  AMI_NAME_DISALLOWED = %r{[^A-Za-z0-9()\[\]./'@_-]+}.freeze
  AMI_NAME_MAX_LENGTH = 128

  def initialize(label)
    @label = label
    @run_id = Time.now.strftime('%Y%m%d-%H%M%S')
    @image_ids = []
  end

  def run(ids, check_only: false, assume_yes: false)
    plan = Flow.plan { make_plan(ids) }
    Flow.execute(plan, heading: "バックアップ（バックアップ作業のタイミング: #{@label}、実行の ID: #{@run_id}。" \
                                'すでにあっても、新しく作る）',
                       check_only: check_only, assume_yes: assume_yes) do |item|
      create_image(item)
    end
  end

  # 1 台ずつ確かめて、バックアップできる・できないに分ける（Item の value はインスタンスの名前）
  def make_plan(ids)
    plan = Flow::Plan.new(title: 'バックアップできる', question: 'バックアップ（AMI の作成。再起動しない）を試行しますか？',
                          keep_title: nil, excluded_title: 'バックアップできない', done_word: '開始')
    plan.finish = ->(_done) { print_next_steps }
    ids.each do |id|
      instance, reasons = inspect_instance(id)
      next plan.excluded << "#{id}  理由: #{reasons.join(' / ')}" unless reasons.empty?

      name = instance_name(instance)
      plan.todo << Flow::Item.new(id, "#{id}  #{name}  #{instance.dig('State', 'Name')}", name)
    end
    plan
  end

  # AMI の作成を始める。済んだときの説明（AMI の ID と名前）を返す
  def create_image(item)
    name = image_name(item.id, item.value)
    tags = tag_specifications('Name' => name, 'SourceInstanceId' => item.id, 'SourceInstanceName' => item.value,
                              'BackupRunId' => @run_id, LABEL_TAG => @label)
    # [変更] AMI を作る。値が "-" で始まってもオプションと取り違えないよう、"--名前=値" の形で渡す
    image_id = AwsCli.run('ec2', 'create-image', '--instance-id', item.id, "--name=#{name}", '--no-reboot',
                          "--description=Backup of #{item.id} before ssm-setup (label #{@label}, run #{@run_id})",
                          "--tag-specifications=#{tags.to_json}")['ImageId']
    @image_ids << image_id
    "#{image_id}（#{name}）"
  end

  def print_next_steps
    puts 'AMI の作成は完了を待っていない（取り始めた時点の中身が残る）。作成が終わったかは次で確かめ、' \
         "#{MAX_AGE_HOURS} 時間以内に、そろった台の一覧の台にだけ SSM Agent の導入を行う:",
         "  ruby rb/backup_check.rb --backup-label #{@label} --ok-out backup-ok.txt < ng.txt",
         "  aws ec2 describe-images --image-ids #{@image_ids.join(' ')} " \
         "--query 'Images[].[ImageId,State,Name]' --output table"
  end

  private

  def instance_name(instance)
    (instance['Tags'] || []).find { |tag| tag['Key'] == 'Name' }&.fetch('Value').to_s
  end

  # [インスタンスの情報, バックアップできない理由の一覧]
  def inspect_instance(id)
    instance = describe_instance(id)
    return [nil, ['インスタンスが見つからない']] unless instance

    [instance, instance_problems(instance)]
  rescue AwsCli::Error => e
    [nil, ["インスタンスの情報を取れない（#{e.summary}）"]]
  end

  # describe-instances の 1 台分。見つからなければ nil
  def describe_instance(id)
    AwsCli.run('ec2', 'describe-instances', '--instance-ids', id).dig('Reservations', 0, 'Instances', 0)
  rescue AwsCli::Error => e
    raise unless NOT_FOUND.include?(e.code)

    nil
  end

  def instance_problems(instance)
    state = instance.dig('State', 'Name')
    problems = []
    problems << "状態が #{state}（running か stopped のときだけ作れる）" unless BACKUP_STATES.include?(state)
    problems << "ルートボリュームが EBS ではない（#{instance['RootDeviceType']}）" unless instance['RootDeviceType'] == 'ebs'
    problems << permission_problem(instance['InstanceId']) if problems.empty?
    problems.compact
  end

  # AMI を作る権限があるかを、実際には作らない試行（--dry-run）で確かめる。問題がなければ nil
  def permission_problem(id)
    AwsCli.run('ec2', 'create-image', '--instance-id', id, '--name', 'ssm-setup-dry-run', '--no-reboot', '--dry-run')
    nil
  rescue AwsCli::Error => e
    return nil if e.code == 'DryRunOperation'
    return 'AMI を作る権限がない（ec2:CreateImage）' if e.code == 'UnauthorizedOperation'

    "AMI を作れるかを確かめられない（#{e.summary}）"
  end

  # AMI の名前: <Name タグ>-<インスタンスの ID>-before-ssm-setup-<実行の ID>。
  # 使えない文字は "-" に置き換え、長すぎるときは先頭（Name タグの側）を削る
  def image_name(instance_id, instance_name)
    label = instance_name.to_s.gsub(AMI_NAME_DISALLOWED, '-').gsub(/\A-+|-+\z/, '')
    name = [label, instance_id, 'before-ssm-setup', @run_id].reject(&:empty?).join('-')
    name[-[AMI_NAME_MAX_LENGTH, name.size].min..].sub(/\A-+/, '')
  end

  # AMI とスナップショットに付けるタグ（create-image の --tag-specifications の形）
  def tag_specifications(tags)
    list = { 'Purpose' => PURPOSE }.merge(tags).map { |key, value| { 'Key' => key, 'Value' => value.to_s } }
    %w[image snapshot].map { |type| { 'ResourceType' => type, 'Tags' => list } }
  end
end

if $PROGRAM_NAME == __FILE__
  options = Cli.parse_options do |o, opts|
    o.on('--backup-label LABEL', 'バックアップ作業のタイミング（例 2026-11）。AMI のタグ BackupLabel の値') { |v| opts[:label] = v }
    Cli.define_run_options(o, opts, 'AMI の作成')
  end
  Cli.usage_error("--backup-label が要る（#{Backup::LABEL_RULE}）") unless Backup::LABEL_PATTERN.match?(options[:label].to_s)
  Cli.require_aws_cli
  exit Backup.new(options[:label]).run(Cli.read_ids, check_only: options[:check_only], assume_yes: options[:yes])
end
