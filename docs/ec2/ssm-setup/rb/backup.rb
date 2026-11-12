#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/backup.rb --backup-label 2026-11 [--check-only] [--yes] < ng.txt
require 'json'
require 'optparse'
require_relative 'backups'
require_relative 'flow'

# SSM Agent の導入の前のバックアップ: インスタンスごとに AMI を作る（create-image --no-reboot。再起動しない。完了は待たない）。
# 確かめる: 1 台ずつ、状態・ルートボリュームの種類・AMI を作る権限を確かめる。
# 行う: 1 台ずつ AMI の作成を始める。作り終わったかは rb/backup_check.rb で確かめる。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class Backup
  BACKUP_STATES = %w[running stopped].freeze

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

      name = SsmSetup.instance_name(instance)
      plan.todo << Flow::Item.new(id, "#{id}  #{name}  #{SsmSetup.instance_state(instance)}", name)
    end
    plan
  end

  # AMI の作成を始める。済んだときの説明（AMI の ID と名前）を返す
  def create_image(item)
    name = Backups.image_name(item.id, item.value, @run_id)
    tags = Backups.tag_specifications('Name' => name, 'SourceInstanceId' => item.id, 'SourceInstanceName' => item.value,
                                      'BackupRunId' => @run_id, Backups::LABEL_TAG => @label)
    # [変更] AMI を作る。値が "-" で始まってもオプションと取り違えないよう、"--名前=値" の形で渡す
    image_id = Tools.aws('ec2', 'create-image', '--instance-id', item.id, "--name=#{name}", '--no-reboot',
                         "--description=Backup of #{item.id} before ssm-setup (label #{@label}, run #{@run_id})",
                         "--tag-specifications=#{tags.to_json}")['ImageId']
    @image_ids << image_id
    "#{image_id}（#{name}）"
  end

  def print_next_steps
    puts 'AMI の作成は完了を待っていない（取り始めた時点の中身が残る）。作成が終わったかは次で確かめ、' \
         "#{Backups::MAX_AGE_HOURS} 時間以内に、そろった台の一覧の台にだけ SSM Agent の導入を行う:",
         "  ruby rb/backup_check.rb --backup-label #{@label} --ok-out backup-ok.txt < ng.txt",
         "  aws ec2 describe-images --image-ids #{@image_ids.join(' ')} " \
         "--query 'Images[].[ImageId,State,Name]' --output table"
  end

  private

  # [インスタンスの情報, バックアップできない理由の一覧]
  def inspect_instance(id)
    instance = SsmSetup.find_instance(id)
    return [nil, ['インスタンスが見つからない']] unless instance

    [instance, instance_problems(instance)]
  rescue Tools::AwsError => e
    [nil, ["インスタンスの情報を取れない（#{e.summary}）"]]
  end

  def instance_problems(instance)
    state = SsmSetup.instance_state(instance)
    problems = []
    problems << "状態が #{state}（running か stopped のときだけ作れる）" unless BACKUP_STATES.include?(state)
    problems << "ルートボリュームが EBS ではない（#{instance['RootDeviceType']}）" unless instance['RootDeviceType'] == 'ebs'
    problems << permission_problem(instance['InstanceId']) if problems.empty?
    problems.compact
  end

  # AMI を作る権限があるかを、実際には作らない試行（--dry-run）で確かめる。問題がなければ nil
  def permission_problem(id)
    Tools.aws('ec2', 'create-image', '--instance-id', id, '--name', 'ssm-setup-dry-run', '--no-reboot', '--dry-run')
    nil
  rescue Tools::AwsError => e
    return nil if e.code == 'DryRunOperation'
    return 'AMI を作る権限がない（ec2:CreateImage）' if e.code == 'UnauthorizedOperation'

    "AMI を作れるかを確かめられない（#{e.summary}）"
  end
end

if $PROGRAM_NAME == __FILE__
  options = SsmSetup.parse_options do |o, opts|
    Backups.define_label_option(o, opts)
    SsmSetup.define_run_options(o, opts, 'AMI の作成')
  end
  Backups.require_label(options[:label])
  SsmSetup.require_aws_cli
  exit Backup.new(options[:label]).run(Tools.read_ids, check_only: options[:check_only], assume_yes: options[:yes])
end
