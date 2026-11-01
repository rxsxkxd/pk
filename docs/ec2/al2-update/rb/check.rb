#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/check.rb [--all] [--exclude PATTERN ...] [--include-apache] [--health-url URL] [--ok-out ok.txt] < ok.txt
require 'optparse'
require_relative 'al2_update'
require_relative 'remote_result'

# 更新の確認（読み取りだけ。何も更新しない）。SSM の Run Command で 1 台ずつ、
# 更新してよいか（remote/preflight.sh）、今の状態（remote/status.sh）、更新される予定のパッケージ（remote/check-updates.sh）を調べ、
# 更新するもの・除くものと、注意が要るもの（httpd・mod_ssl・openssl・カーネルなど）を表示する。
# rb/update.rb に同じ指定（--all・--exclude・--include-apache）を渡せば、ここで見たものと同じ範囲を更新する。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class UpdateCheck
  def initialize(settings:, ok_out:)
    @settings = settings
    @ok_out = ok_out
  end

  # 流れ: 1 台ずつ調べて表示する → 一覧を書き出す → 結果を表示する
  def run(ids)
    puts "== 更新の確認（#{AL2Update.describe_settings(@settings)}。読み取りだけ）"
    results = inspect_all(ids)
    write_list(results)
    print_summary(results)
    results.values.all? { |result| result.problem.nil? } ? 0 : 1
  end

  # 1 台ずつ調べて表示する。インスタンスの ID → 結果（RemoteResult）
  def inspect_all(ids)
    ids.to_h do |id|
      result = RemoteResult.new(AL2Update.run_script(id, AL2Update.inspect_script(@settings)))
      print_instance(id, result)
      [id, result]
    end
  end

  # 一覧を書き出す（--ok-out。調べられた台のうち、更新するものがある台。rb/backup.rb と rb/update.rb に渡せる）
  def write_list(results)
    ids = results.keys.reject { |id| updates_of(results[id]).empty? }
    lines = ['# 更新するものがある台（rb/backup.rb と rb/update.rb の標準入力に渡せる）', *ids]
    File.write(@ok_out, lines.map { |line| "#{line}\n" }.join)
  end

  def print_summary(results)
    lists = checked_update_lists(results)
    with_attention = lists.count { |list| !AL2Update.attention_names(list).empty? }
    puts "== 結果: 調べた #{lists.size} 台（更新するものがある #{lists.count { |list| !list.empty? }} 台、" \
         "うち注意が要るものを含む #{with_attention} 台）、調べられない #{results.size - lists.size} 台"
  end

  private

  # 調べられた台ごとの、更新するパッケージの一覧
  def checked_update_lists(results)
    results.values.reject(&:problem).map { |result| updates_of(result) }
  end

  # 更新するパッケージの一覧（除くものを除く。調べられなかった台は空）
  def updates_of(result)
    result.problem ? [] : result.updates(@settings.excludes)
  end

  def print_instance(id, result)
    if result.problem
      puts "調べられない  #{id}  #{result.problem}"
      return
    end
    print_heading(id, result)
    print_packages(result)
    puts '   注意: 出力が 24,000 文字で切れた（一覧は途中まで。--exclude で絞るか、台に入って yum check-update で見る）' \
      unless result.complete?
  end

  def print_heading(id, result)
    updates = updates_of(result)
    puts "== #{id}  更新する #{updates.size} 件、除く #{result.entries('pending').size - updates.size} 件"
    puts "   #{result.status_line}", "   #{result.restart_services_line}", "   #{result.versions_line}",
         "   yum-cron（自動の更新） #{result['yum_cron_enabled']}"
  end

  # パッケージを 1 行に 1 つ、「更新する」か「除く」かと、注意が要る理由をつけて表示する
  def print_packages(result)
    result.entries('pending').each do |entry|
      kind = AL2Update.matches?(entry.split.first, @settings.excludes) ? '除く    ' : '更新する'
      puts "   #{kind}  #{AL2Update.with_attention(entry)}"
    end
  end
end

def parse_options
  options = AL2Update.default_update_options.merge(ok_out: File::NULL)
  OptionParser.new do |o|
    AL2Update.define_update_options(o, options)
    o.on('--ok-out PATH', '更新するものがある台の一覧を書き出す') { |v| options[:ok_out] = v }
  end.parse!
  options
rescue OptionParser::ParseError => e
  AL2Update.usage_error(e.message)
end

options = parse_options
AL2Update.require_aws_cli
exit UpdateCheck.new(settings: AL2Update.settings_from(options), ok_out: options[:ok_out]).run(Tools.read_ids)
