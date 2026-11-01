#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/update.rb --backup-label 2026-11 [--all] [--exclude PATTERN ...] [--include-apache] [--health-url URL]
#                     [--record al2-update-<日時>.json] [--check-only] [--yes] < ok.txt
require 'json'
require 'optparse'
require_relative 'al2_update'
require_relative 'backups'
require_relative 'remote_result'
require_relative 'update_outcome'

# yum でパッケージを更新する（SSM の Run Command で 1 台ずつ。再起動はしない。サービスの再起動もしない）。
# 既定はセキュリティの更新だけで、Apache（httpd*・mod_*）は除く（rb/check.rb と同じ指定で、同じ範囲になる）。
# 1 台の更新の後に、httpd が動いているか・アプリが応答するかを更新の前と比べ、悪くなったら残りの台を止める。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class PackageUpdate
  def initialize(label:, settings:, record_path:)
    @label = label
    @settings = settings
    @run_id = Time.now.strftime('%Y%m%d-%H%M%S')
    @record_path = record_path || "al2-update-#{@run_id}.json"
    @skipped = {} # 更新しなかった台: インスタンスの ID → [区分, 理由]
  end

  # 流れ: バックアップの確認 → 更新してよいかの確認（更新される予定の表示）→ [y/N] の確認
  #       → 1 台ずつ更新して確かめる（問題が出たら残りを止める）→ 結果の表示と記録
  def run(ids, check_only: false, assume_yes: false)
    puts "== 更新（#{AL2Update.describe_settings(@settings)}。実行の ID: #{@run_id}）"
    backups = check_backups(ids)
    befores = check_updatable(backups.keys)
    return finish_without_update(befores) if check_only || befores.empty?
    return 0 unless confirmed?(befores.size, assume_yes)

    outcomes = update_each(befores)
    write_record(outcomes, backups)
    print_summary(outcomes)
    exit_code(outcomes)
  end

  # バックアップの確認: 条件に合う AMI がある台だけを残す。インスタンスの ID → AMI の ID
  def check_backups(ids)
    found = UpdateBackups.check_all(ids, @label)
    found.each { |id, result| @skipped[id] = ['バックアップなし', result.reason] unless result.ok }
    found.select { |_, result| result.ok }.to_h { |id, result| [id, result.image_id] }
  end

  # 更新してよいかの確認: インスタンスの側で確かめ（preflight.sh）、更新の前の状態と、更新される予定を表示する。
  # 更新する台だけを残す。インスタンスの ID → 更新の前の状態（RemoteResult）
  def check_updatable(ids)
    ids.to_h { |id| [id, inspect_before(id)] }.compact
  end

  # 1 台ずつ更新して確かめる。問題が出たら（更新の失敗を含む）、残りの台は行わない
  def update_each(befores)
    outcomes = []
    befores.each do |id, before|
      outcome = UpdateOutcome.new(id, before, update_instance(id))
      outcome.print_report
      outcomes << outcome
      next if outcome.status == '更新した'

      stop_remaining(befores.keys.drop(outcomes.size))
      break
    end
    outcomes
  end

  def print_summary(outcomes)
    counts = %w[更新した 問題あり 失敗].map { |kind| "#{kind} #{outcomes.count { |o| o.status == kind }} 台" }
    puts "== 結果: #{(counts + skipped_counts).join('、')}（記録 #{@record_path}）"
    print_reboot_note(outcomes)
  end

  private

  # 更新をしないで終わる（--check-only か、更新できる台がない）。確かめた結果だけを表示する
  def finish_without_update(befores)
    puts "== 確認の結果: #{["更新できる #{befores.size} 台", *skipped_counts].join('、')}（更新はしていない）"
    exit_code([])
  end

  def skipped_counts
    @skipped.values.group_by(&:first).map { |kind, list| "#{kind} #{list.size} 台" }
  end

  def print_reboot_note(outcomes)
    return unless outcomes.any? { |outcome| outcome.to_h['needs_reboot'] == 'yes' }

    puts '再起動は道具では行わない。「再起動が要る」の台は、README の「再起動」の手順で、1 台ずつ行う'
  end

  # 0: バックアップなし・更新できない・止めた・問題あり・失敗の台がない（更新なしの台は問題にしない）。1: ある
  def exit_code(outcomes)
    skipped = @skipped.values.reject { |kind, _| kind == '更新なし' }
    failed = outcomes.reject { |outcome| outcome.status == '更新した' }
    skipped.empty? && failed.empty? ? 0 : 1
  end

  # 1 台を調べて表示する。更新できれば更新の前の状態を返す（できなければ、更新しなかった台に入れて nil）
  def inspect_before(id)
    before = RemoteResult.new(AL2Update.run_script(id, AL2Update.inspect_script(@settings)))
    kind, reason = classify(before)
    puts "#{kind}  #{id}  #{reason}"
    return before if kind == '更新できる'

    @skipped[id] = [kind, reason]
    nil
  end

  # [区分, 説明]。区分は 更新できる・更新できない・更新なし
  def classify(before)
    return ['更新できない', before.problem] if before.problem
    return ['更新できない', '出力が 24,000 文字で切れた（--exclude で絞るか、台に入って yum check-update で見る）'] unless before.complete?

    updates = before.updates(@settings.excludes)
    return %w[更新なし 更新するものがない] if updates.empty?

    names = AL2Update.attention_names(updates)
    note = names.empty? ? '' : "（注意が要るもの: #{names.join(' ')}）"
    ['更新できる', "更新する #{updates.size} 件#{note}  #{before.status_line}"]
  end

  def confirmed?(count, assume_yes)
    question = "上の「更新できる」#{count} 台を、1 台ずつ yum で更新しますか？（再起動はしない。問題が出たら残りを止める）"
    return true if assume_yes || Tools.ask(question)

    puts '中止した'
    false
  end

  # 1 台を更新する。更新の後の状態（RemoteResult）を返す
  def update_instance(id)
    puts "-- #{id} を更新する"
    RemoteResult.new(AL2Update.run_script(id, AL2Update.update_script(@settings, @run_id))) # [変更]
  end

  def stop_remaining(ids)
    ids.each { |id| @skipped[id] = %w[止めたので行わなかった 前の台で問題が出た] }
    puts "残りの #{ids.size} 台を止めた（問題を確かめてから、もう一度この道具に渡す）" unless ids.empty?
  end

  # 記録: 更新を試した台の結果（変わったパッケージ、yum の履歴の ID、バックアップの AMI）と、更新しなかった台の理由
  def write_record(outcomes, backups)
    instances = outcomes.to_h { |o| [o.id, o.to_h.merge('backup_image' => backups[o.id])] }
    @skipped.each { |id, (kind, reason)| instances[id] = { 'status' => kind, 'reason' => reason } }
    record = { 'run_id' => @run_id, 'backup_label' => @label, 'scope' => @settings.scope,
               'excludes' => @settings.excludes, 'instances' => instances }
    File.write(@record_path, "#{JSON.pretty_generate(record)}\n")
  end
end

def parse_options
  options = AL2Update.default_update_options
  OptionParser.new do |o|
    UpdateBackups.define_label_option(o, options)
    AL2Update.define_update_options(o, options)
    o.on('--record PATH', '記録を書くファイル（既定 al2-update-<実行の ID>.json）') { |v| options[:record] = v }
    AL2Update.define_run_options(o, options, '更新')
  end.parse!
  options
rescue OptionParser::ParseError => e
  AL2Update.usage_error(e.message)
end

options = parse_options
UpdateBackups.require_label(options[:label])
AL2Update.require_aws_cli
update = PackageUpdate.new(label: options[:label], settings: AL2Update.settings_from(options),
                           record_path: options[:record])
exit update.run(Tools.read_ids, check_only: options[:check_only], assume_yes: options[:yes])
