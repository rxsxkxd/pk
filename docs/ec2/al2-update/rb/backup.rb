#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/backup.rb --backup-label 2026-11 [--check-only] [--yes] < ok.txt
require 'json'
require 'optparse'
require_relative 'al2_update'
require_relative 'backups'

# 更新の前のバックアップ: インスタンスごとに AMI を作る（create-image --no-reboot。再起動しない。完了は待たない）。
# ssm-setup/py/ssm_setup_backup/backup.py と同じ考え方で、タグ Purpose だけを al2-update-backup に分ける。
# 作り終わったかは rb/backup_check.rb で確かめる（rb/update.rb も、更新の前に同じ条件で確かめる）。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class UpdateBackup
  BACKUP_STATES = %w[running stopped].freeze

  def initialize(label:)
    @label = label
    @run_id = Time.now.strftime('%Y%m%d-%H%M%S')
  end

  # 流れ: 1 台ずつバックアップできるかを確かめる → [y/N] の確認 → 1 台ずつ AMI の作成を始める → 確かめ方を表示する
  def run(ids, check_only: false, assume_yes: false)
    puts "== バックアップ（バックアップ作業のタイミング: #{@label}、実行の ID: #{@run_id}。すでにあっても、新しく作る）"
    instances, excluded = inspect_all(ids)
    return exit_code(excluded) if check_only || instances.empty?
    return 0 unless confirmed?(instances, assume_yes)

    started, failed = create_all(instances)
    print_next_steps(started)
    exit_code(excluded + failed)
  end

  # 1 台ずつ、状態・ルートボリュームの種類・AMI を作る権限を確かめて表示する。
  # [バックアップできる台の情報（describe-instances）の一覧, できない台の ID の一覧]
  def inspect_all(ids)
    results = ids.map { |id| [id, *inspect_instance(id)] }
    results.each { |id, instance, reasons| print_inspection(id, instance, reasons) }
    backupable, excluded = results.partition { |_, _, reasons| reasons.empty? }
    [backupable.map { |_, instance, _| instance }, excluded.map(&:first)]
  end

  # 1 台ずつ AMI の作成を始める。[作り始めた AMI の ID の一覧, 失敗した台の ID の一覧]
  def create_all(instances)
    results = instances.map { |instance| [instance['InstanceId'], start_backup(instance)] }
    started, failed = results.partition { |_, image_id| image_id }
    [started.map(&:last), failed.map(&:first)]
  end

  def print_next_steps(image_ids)
    return if image_ids.empty?

    puts 'AMI の作成は完了を待っていない（取り始めた時点の中身が残る）。作成が終わって（available）から、' \
         "#{UpdateBackups::MAX_AGE_HOURS} 時間以内に、同じ --backup-label で rb/update.rb を行う。進み具合は次で確かめる:",
         "  ruby rb/backup_check.rb --backup-label #{@label} < ok.txt",
         "  aws ec2 describe-images --image-ids #{image_ids.join(' ')} --query 'Images[].[ImageId,State,Name]' " \
         '--output table'
  end

  private

  def exit_code(problems)
    problems.empty? ? 0 : 1
  end

  def confirmed?(instances, assume_yes)
    question = "上の「バックアップできる」#{instances.size} 台の、バックアップ（AMI の作成。再起動しない）を試行しますか？"
    return true if assume_yes || Tools.ask(question)

    puts '中止した'
    false
  end

  def print_inspection(id, instance, reasons)
    if reasons.empty?
      puts "バックアップできる    #{id}  #{instance_name(instance) || '(Name なし)'}  #{instance.dig('State', 'Name')}"
    else
      puts "バックアップできない  #{id}  #{reasons.join(' / ')}"
    end
  end

  # [インスタンスの情報, バックアップできない理由の一覧]
  def inspect_instance(id)
    instance = Tools.aws('ec2', 'describe-instances', '--instance-ids', id).dig('Reservations', 0, 'Instances', 0)
    return [nil, ['インスタンスが見つからない']] unless instance

    [instance, instance_problems(instance)]
  rescue Tools::AwsError => e
    [nil, ["インスタンスの情報を取れない（#{e.message.lines.last.to_s.strip}）"]]
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
    Tools.aws('ec2', 'create-image', '--instance-id', id, '--name', 'al2-update-dry-run', '--no-reboot', '--dry-run')
    nil
  rescue Tools::AwsError => e
    return nil if e.message.include?('DryRunOperation')
    return 'AMI を作る権限がない（ec2:CreateImage）' if e.message.include?('UnauthorizedOperation')

    "AMI を作れるかを確かめられない（#{e.message.lines.last.to_s.strip}）"
  end

  # AMI の作成を始めて表示する。作り始めた AMI の ID を返す（失敗なら nil）
  def start_backup(instance)
    id = instance['InstanceId']
    image_id = create_image(instance)
    puts "開始  #{id}  #{image_id}"
    image_id
  rescue Tools::AwsError => e
    puts "失敗  #{id}  #{e.message.lines.last.to_s.strip}"
    nil
  end

  def create_image(instance)
    id = instance['InstanceId']
    name = UpdateBackups.image_name(id, instance_name(instance), @run_id)
    tags = UpdateBackups.tag_specifications('Name' => name, 'SourceInstanceId' => id,
                                            'SourceInstanceName' => instance_name(instance),
                                            'BackupRunId' => @run_id, UpdateBackups::LABEL_TAG => @label)
    # [変更] 値が "-" で始まってもオプションと取り違えないよう、"--名前=値" の形で渡す
    Tools.aws('ec2', 'create-image', '--instance-id', id, "--name=#{name}", '--no-reboot',
              "--description=Backup of #{id} before al2-update (label #{@label}, run #{@run_id})",
              "--tag-specifications=#{tags.to_json}")['ImageId']
  end

  def instance_name(instance)
    (instance['Tags'] || []).find { |tag| tag['Key'] == 'Name' }&.fetch('Value')
  end
end

def parse_options
  options = {}
  OptionParser.new do |o|
    UpdateBackups.define_label_option(o, options)
    AL2Update.define_run_options(o, options, 'AMI の作成')
  end.parse!
  options
rescue OptionParser::ParseError => e
  AL2Update.usage_error(e.message)
end

options = parse_options
UpdateBackups.require_label(options[:label])
AL2Update.require_aws_cli
exit UpdateBackup.new(label: options[:label]).run(Tools.read_ids, check_only: options[:check_only],
                                                                  assume_yes: options[:yes])
