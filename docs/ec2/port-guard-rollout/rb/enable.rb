#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/enable.rb --backup-label 2026-10 [--revert-minutes 10] [--yes] < ok.txt
require 'optparse'
require 'shellwords'
require_relative 'port_guard'

# 遮断を 1 台ずつ有効にする（SSM の Run Command）。台ごとに y/n/q で確かめ、自動で元に戻る予約を入れてから有効にし、
# SSM で引き続き入れるか・作業者の PC から対象のポートが応答するかを確かめて、合格なら確定、不合格ならすぐに戻す。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class PortGuardEnable
  CHOICES = %w[y n q].freeze

  def initialize(label:, revert_minutes:)
    @label = label
    @revert_minutes = revert_minutes
    @run_id = Time.now.strftime('%Y%m%d-%H%M%S')
  end

  # 流れ: バックアップの確認 → 1 台ずつ、確かめながら有効にする → 結果を表示する
  def run(ids, assume_yes: false)
    with_backup, without_backup = PortGuard.check_backups(ids, @label)
    results = enable_each(with_backup, assume_yes)
    print_summary(results, with_backup.size - results.size, without_backup.size)
    results.values.all?('確定') && results.size == ids.size ? 0 : 1
  end

  # 1 台ずつ、確かめながら有効にする。インスタンスの ID → 結果（確定・戻した・失敗・飛ばした）
  def enable_each(ids, assume_yes)
    results = {}
    ids.each do |id|
      answer = assume_yes ? 'y' : ask_checkpoint(id)
      if answer == 'q'
        puts '残りを止めた'
        break
      end
      results[id] = answer == 'y' ? enable_with_checkpoint(id) : '飛ばした'
    end
    results
  end

  # 1 台の有効化: 予約を入れて有効にする → 確かめる → 合格なら確定、不合格ならすぐに戻す
  def enable_with_checkpoint(id)
    revert, ports = apply_with_auto_revert(id)
    return '失敗' unless revert

    problems = verify(id, ports)
    problems.empty? ? confirm(id, revert) : revert_now(id, revert, problems)
  end

  # 有効化: 決めた時間の後に自動で元に戻る予約を入れてから有効にする（入れてよいかもインスタンスの側で確かめる）。
  # [予約, 対象のポート] を返す（有効にできなければ予約は nil）
  def apply_with_auto_revert(id)
    result = PortGuard.run_script(id, apply_script)
    values = PortGuard.values(result)
    problem = PortGuard.blocked_reasons(result).first || PortGuard.failure(result)
    return applied(values) unless problem

    puts "  有効にできない: #{problem}"
    revert_now(id, values['revert'], [problem]) if values['revert'] # 途中で失敗したら、すぐに戻す
    [nil, []]
  end

  # 確かめる: SSM で引き続き入れるか、作業者の PC から対象のポートが応答するか。問題の一覧を返す
  def verify(id, ports)
    problems = []
    problems << 'SSM で入れなくなった' unless PortGuard.failure(PortGuard.run_script(id, "echo 'PG reachable=yes'")).nil?
    ip = PortGuard.address_of(id)
    ports.each do |port|
      ok = PortGuard.responds?(ip, port)
      puts "  確認: #{ip}:#{port} が#{ok ? '応答する' : '応答しない'}"
      problems << "#{port} 番が応答しない" unless ok
    end
    problems
  end

  def print_summary(results, untouched, without_backup)
    counts = %w[確定 戻した 失敗 飛ばした].map { |kind| "#{kind} #{results.values.count(kind)} 台" }
    puts "== 結果: #{counts.join('、')}、止めたので行わなかった #{untouched} 台、バックアップなし #{without_backup} 台" \
         "（実行の ID: #{@run_id}）"
  end

  private

  def ask_checkpoint(id)
    prompt = "== #{id}  この台の遮断を有効にしますか？（#{@revert_minutes} 分後に自動で元に戻る予約を入れてから行う）" \
             '[y: 進める / n: 飛ばす / q: 残りを止める]: '
    File.open('/dev/tty', 'r+') { |tty| read_choice(tty, prompt) }
  rescue SystemCallError
    'q' # 端末がなければ、何もせずに止める（確かめずに進めるなら --yes）
  end

  # 選択肢のどれかが入るまで聞き直す。入力が終わったら q（残りを止める）
  def read_choice(tty, prompt)
    loop do
      tty.print(prompt)
      answer = tty.gets&.strip
      return 'q' if answer.nil?
      return answer if CHOICES.include?(answer)
    end
  end

  def apply_script
    "PG_RUN_ID=#{@run_id} PG_REVERT_MINUTES=#{@revert_minutes}\n" +
      PortGuard.remote_file('enable-preflight.sh', 'enable-apply.sh')
  end

  def applied(values)
    puts "  有効にした（ポート #{values['ports']}、予約 #{values['revert']}）"
    [values['revert'], values['ports'].to_s.split(',')]
  end

  # 予約（revert）を渡して、確定（enable-confirm.sh）か元に戻す処理（enable-revert.sh）を送る
  def revert_script(revert, name)
    "PG_REVERT=#{Shellwords.escape(revert)}\n#{PortGuard.remote_file(name)}"
  end

  def confirm(id, revert)
    problem = PortGuard.failure(PortGuard.run_script(id, revert_script(revert, 'enable-confirm.sh')))
    puts problem ? "  予約の取り消しに失敗（#{problem}）。#{@revert_minutes} 分後に自動で元に戻る" : '  確定'
    problem ? '失敗' : '確定'
  end

  def revert_now(id, revert, problems)
    puts "  不合格: #{problems.join(' / ')}。すぐに元に戻す（SSM で入れないときは #{@revert_minutes} 分後に予約で戻る）"
    PortGuard.run_script(id, revert_script(revert, 'enable-revert.sh'))
    '戻した'
  end
end

def parse_options
  options = { revert_minutes: 10 }
  OptionParser.new do |o|
    o.on('--backup-label LABEL') { |v| options[:label] = v }
    o.on('--revert-minutes MINUTES', Integer) { |v| options[:revert_minutes] = v }
    o.on('--yes') { options[:yes] = true }
  end.parse!
  abort '--backup-label が要る' unless options[:label]
  options
end

options = parse_options
enable = PortGuardEnable.new(label: options[:label], revert_minutes: options[:revert_minutes])
exit enable.run(Tools.read_ids, assume_yes: options[:yes])
