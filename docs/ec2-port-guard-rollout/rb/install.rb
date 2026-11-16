#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/install.rb --backup-label 2026-10 [--allow-file allow.txt] [--include-ssh] [--check-only] [--yes] < ok.txt
require 'optparse'
require 'shellwords'
require_relative 'port_guard'

# ipset の導入と設定を、SSM の Run Command で 1 台ずつ行う（遮断はまだ効かせない）。
# 入れてよいかは、インスタンスの側で確かめる（remote/install-preflight.sh。問題があれば理由を出して何もしない）。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class PortGuardInstall
  def initialize(label:, ports:, allow_file:)
    @label = label
    @ports = ports
    @allow_file = allow_file
  end

  # 流れ: バックアップの確認 → 入れてよいかの確認 → 導入
  def run(ids, check_only: false, assume_yes: false)
    with_backup, without_backup = PortGuard.check_backups(ids, @label)
    installable, blocked = check_preflight(with_backup)
    not_installable = without_backup + blocked
    return exit_code(not_installable) if check_only || installable.empty?
    return 0 unless confirmed?(installable, assume_yes)

    exit_code(not_installable + install_all(installable))
  end

  # 入れてよいかの確認: インスタンスの側で install-preflight.sh を動かし（読み取りだけ）、入れられる台と入れられない台に分ける
  def check_preflight(ids)
    ids.partition do |id|
      result = PortGuard.run_script(id, PortGuard.remote_file('install-preflight.sh'))
      reasons = PortGuard.blocked_reasons(result)
      reasons << PortGuard.failure(result) if reasons.empty? && PortGuard.failure(result)
      puts reasons.empty? ? "入れられる    #{id}" : "入れられない  #{id}  #{reasons.join(' / ')}"
      reasons.empty?
    end
  end

  # 導入: 1 台ずつ、ipset と python3 を入れ、設定・スクリプト・ユニットを置き、集合を作る。失敗した台を返す
  def install_all(ids)
    script = install_script
    failed = ids.select { |id| install_problem(id, script) }
    puts '集合の中身（日本の IP の範囲と許可する IP）は今回の実行の時点のもの（新しくするには、有効にする前にもう一度入れる）'
    failed
  end

  private

  def exit_code(problems)
    problems.empty? ? 0 : 1
  end

  def confirmed?(ids, assume_yes)
    puts '注意: 22 番（SSH）も対象にする。日本の IP か許可する IP からしか SSH で入れなくなる' if @ports.include?('22')
    question = "上の「入れられる」#{ids.size} 台に、ipset の導入と設定（ポート #{@ports}。遮断はまだ効かせない）を試行しますか？"
    return true if assume_yes || Tools.ask(question)

    puts '中止した'
    false
  end

  # 1 台に入れて表示する。失敗なら問題の説明を返す（済めば nil）
  def install_problem(id, script)
    result = PortGuard.run_script(id, script)
    problem = PortGuard.blocked_reasons(result).first || PortGuard.failure(result)
    values = PortGuard.values(result)
    summary = "日本の範囲 #{values['jp_entries']} 件、許可する IP #{values['allow_entries']} 件"
    puts problem ? "失敗  #{id}  #{problem}" : "完了  #{id}  #{summary}"
    problem
  end

  # 送るもの: 渡す値（PG_*）、入れてよいかの確認、導入の本体
  def install_script
    prelude = {
      'PG_PORTS' => @ports, 'PG_JP_MIN_ENTRIES' => '1000', 'PG_CHECK_IN_JP' => '', 'PG_CHECK_OUTSIDE' => '',
      'PG_ALLOW_B64' => base64(@allow_file ? File.read(@allow_file) : ''),
      'PG_APPLY_B64' => base64(PortGuard.remote_file('port-guard-apply')),
      'PG_UPDATE_JP_B64' => base64(PortGuard.remote_file('port-guard-update-jp')),
      'PG_SERVICE_B64' => base64(PortGuard.remote_file('port-guard.service'))
    }.map { |key, value| "#{key}=#{Shellwords.escape(value)}\n" }.join
    prelude + PortGuard.remote_file('install-preflight.sh', 'install.sh')
  end

  def base64(text)
    [text].pack('m0')
  end
end

def parse_options
  options = { ports: '80,443' }
  OptionParser.new do |o|
    o.on('--backup-label LABEL') { |v| options[:label] = v }
    o.on('--allow-file PATH') { |v| options[:allow_file] = v }
    o.on('--include-ssh') { options[:ports] = '22,80,443' }
    o.on('--check-only') { options[:check_only] = true }
    o.on('--yes') { options[:yes] = true }
  end.parse!
  abort '--backup-label が要る' unless options[:label]
  options
end

options = parse_options
install = PortGuardInstall.new(label: options[:label], ports: options[:ports], allow_file: options[:allow_file])
exit install.run(Tools.read_ids, check_only: options[:check_only], assume_yes: options[:yes])
