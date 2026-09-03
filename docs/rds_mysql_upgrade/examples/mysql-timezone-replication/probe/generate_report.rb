#!/usr/bin/env ruby
# frozen_string_literal: true
#
# ドライバ検証レポートの生成（3 言語共通）。
#
# 各言語の probe が出力した JSON を読み、判定を行って Markdown を生成する。
# DB へは接続しない。収集（probe）と判定（本スクリプト）を分離している。
#
# 入力 JSON のスキーマ（schema_version: 1）:
#   {
#     "schema_version": 1,
#     "language": "Go",                      // 表示名。出力ファイル名にも使う
#     "driver": "go-sql-driver/mysql",
#     "timezone_layer": "...",               // そのドライバのタイムゾーン層の説明
#     "issues_set_time_zone": false,         // サーバーへ SET time_zone を発行するか
#     "setting_label": "loc",                // 設定項目の呼び名（表の見出しに使う）
#     "collected_at": "2026-09-03T12:00:00Z",
#     "read_results": [                      // 設定を接続先に合わせた場合の読み取り
#       { "section": "...", "detail": "...", "id": 1,
#         "driver_value": "...", "driver_unix": 0, "server_unix": 0 }
#     ],
#     "contrast": { "title": "...", "results": [ /* read_results と同形 */ ] },
#     "server_side": [                       // サーバー側で確定する結果
#       { "label": "source", "setting": "loc=UTC",
#         "where_matched": 1, "date_groups": 2 }
#     ]
#   }
#
# 判定（すべて満たせば PASS）:
#   1. read_results がすべて driver_unix == server_unix   … 吸収できている
#   2. contrast に driver_unix != server_unix が存在する    … 誤設定ならずれる
#   3. 同じ label 内で where_matched / date_groups が一定  … 設定では吸収できない
#   4. label 間で where_matched / date_groups が異なる      … 接続先で結果が変わる
#
# 不適合が 1 つでもあれば終了コード 1 を返す。

require 'json'
require 'optparse'
require 'fileutils'

SCHEMA_VERSION = 1

options = { input_dir: ENV.fetch('REPORT_DIR', '/probe/reports'), output_dir: nil }
OptionParser.new do |parser|
  parser.on('--input-dir DIR', '収集済み JSON の場所（default: /probe/reports）') { |v| options[:input_dir] = v }
  parser.on('--output-dir DIR', 'Markdown の出力先（default: --input-dir と同じ）') { |v| options[:output_dir] = v }
end.parse!
options[:output_dir] ||= options[:input_dir]

def mark(ok) = ok ? 'OK' : '**NG**'
def verdict(ok) = ok ? '**PASS**' : '**FAIL**'

# JSON 1 件分の判定結果をまとめる。
def evaluate(data)
  read = data.fetch('read_results')
  contrast = data.dig('contrast', 'results') || []
  server = data.fetch('server_side')

  by_label = server.group_by { |r| r['label'] }
  {
    absorbed: read.all? { |r| r['driver_unix'] == r['server_unix'] },
    contrast_differs: contrast.any? { |r| r['driver_unix'] != r['server_unix'] },
    # 同じ接続先なら、ドライバ設定を変えても結果が変わらないこと。
    stable_per_host: by_label.values.all? { |rows|
      rows.map { |r| [r['where_matched'], r['date_groups']] }.uniq.size == 1
    },
    # 接続先が変われば結果が変わること。
    differs_by_host: by_label.values.map { |rows|
      [rows.first['where_matched'], rows.first['date_groups']]
    }.uniq.size > 1
  }
end

def render(data, judgment)
  setting = data.fetch('setting_label')
  passed = judgment.values.all?
  out = +''

  out << "# ドライバ検証レポート: #{data['language']}\n\n"
  out << "| 項目 | 値 |\n|---|---|\n"
  out << "| 言語 | #{data['language']} |\n"
  out << "| ドライバ | #{data['driver']} |\n"
  out << "| タイムゾーン層 | #{data['timezone_layer']} |\n"
  out << "| サーバーへ `SET time_zone` を発行するか | #{data['issues_set_time_zone'] ? 'する' : '**しない**'} |\n"
  out << "| 収集時刻 | #{data['collected_at']} |\n"
  out << "| 総合判定 | #{verdict(passed)} |\n\n"

  out << "## 1. 読み取り値の解釈（#{setting} を接続先に合わせた場合）\n\n"
  out << "ドライバが解釈した絶対時刻が、サーバーの `UNIX_TIMESTAMP(ts)` と一致すれば吸収できている。\n"
  out << "`UNIX_TIMESTAMP()` は `TIMESTAMP` 列に対して内部表現をそのまま返すため、\n"
  out << "セッションのタイムゾーンに依存しない絶対値である。\n\n"
  out << "| 接続 | id | ドライバの解釈 | driver_unix | server_unix | 一致 |\n|---|---|---|---|---|---|\n"
  data['read_results'].each do |r|
    out << "| #{r['section']} | #{r['id']} | `#{r['driver_value']}` | " \
           "#{r['driver_unix']} | #{r['server_unix']} | #{mark(r['driver_unix'] == r['server_unix'])} |\n"
  end
  out << "\n判定: #{verdict(judgment[:absorbed])}"
  out << (judgment[:absorbed] ? "（すべて一致した。ドライバがタイムゾーン差を吸収できている）\n\n" : "（一致しない行がある）\n\n")

  contrast = data['contrast']
  if contrast && !Array(contrast['results']).empty?
    out << "## 2. 対比: #{contrast['title']}\n\n"
    out << "| 接続 | id | ドライバの解釈 | driver_unix | server_unix | 一致 |\n|---|---|---|---|---|---|\n"
    contrast['results'].each do |r|
      out << "| #{r['section']} | #{r['id']} | `#{r['driver_value']}` | " \
             "#{r['driver_unix']} | #{r['server_unix']} | #{mark(r['driver_unix'] == r['server_unix'])} |\n"
    end
    out << "\n判定: #{verdict(judgment[:contrast_differs])}"
    out << (judgment[:contrast_differs] ? "（設定を誤ると実際にずれることを確認した）\n\n" : "（ずれが再現しなかった）\n\n")
  end

  out << "## 3. サーバー側で確定する結果（ドライバ設定では吸収できない）\n\n"
  out << "`WHERE` 句のリテラル解釈と `GROUP BY DATE()` の集計は、ドライバへ渡る時点で\n"
  out << "既に行が確定している。ドライバ設定を変えても結果は変わらない。\n\n"
  out << "| 接続 | ドライバ設定 | where_matched | date_groups |\n|---|---|---|---|\n"
  data['server_side'].each do |r|
    out << "| #{r['label']} | `#{r['setting']}` | #{r['where_matched']} | #{r['date_groups']} |\n"
  end
  out << "\n"
  out << "- 同じ接続先で #{setting} を変えても値が変わらない: #{verdict(judgment[:stable_per_host])}\n"
  out << "- 接続先が変わると値が変わる: #{verdict(judgment[:differs_by_host])}\n\n"
  out << "この 2 つが同時に成立することは、差がサーバー側で確定しており\n"
  out << "**ドライバ設定では吸収できない**ことを意味する。\n\n"

  out << "## 結論\n\n"
  out << if passed
           "- 読み取り値の解釈は、#{setting} を接続先のセッション `time_zone` に合わせれば**吸収できる**\n" \
           "- `WHERE` 句と `GROUP BY DATE()` の差は**吸収できない**。" \
           "セッションのタイムゾーンを固定するか、リテラルを使わない書き方で対処する\n"
         else
           "検証が期待どおりに成立しなかった。上記の FAIL 項目を確認する。\n"
         end
  out
end

def render_summary(entries)
  out = +"# ドライバ検証レポート: 3 言語の比較\n\n"
  out << "各言語の probe が収集した JSON から生成している。判定基準は 3 言語で同一である。\n\n"
  out << "## 総合判定\n\n"
  out << "| 言語 | ドライバ | `SET time_zone` を発行 | 判定 |\n|---|---|---|---|\n"
  entries.each do |data, judgment|
    out << "| #{data['language']} | #{data['driver']} | " \
           "#{data['issues_set_time_zone'] ? 'する' : '**しない**'} | #{verdict(judgment.values.all?)} |\n"
  end

  out << "\n## タイムゾーン層の違い\n\n"
  out << "| 言語 | タイムゾーン層 | 合わせる設定 |\n|---|---|---|\n"
  entries.each do |data, _|
    out << "| #{data['language']} | #{data['timezone_layer']} | `#{data['setting_label']}` |\n"
  end

  out << "\n## 吸収できる範囲とできない範囲\n\n"
  out << "| 言語 | 読み取り値を吸収できるか | 誤設定でずれるか | サーバー側の差を吸収できるか |\n|---|---|---|---|\n"
  entries.each do |data, j|
    out << "| #{data['language']} | #{j[:absorbed] ? '**できる**' : 'できない'} | " \
           "#{j[:contrast_differs] ? 'ずれる' : 'ずれない'} | " \
           "#{j[:stable_per_host] && j[:differs_by_host] ? '**できない**' : '判定不能'} |\n"
  end

  out << "\n## サーバー側で確定する結果の一致\n\n"
  out << "3 言語とも同じ値になるはずである（サーバー側で決まるため、言語に依存しない）。\n\n"
  out << "| 言語 | 接続 | where_matched | date_groups |\n|---|---|---|---|\n"
  entries.each do |data, _|
    data['server_side'].each do |r|
      out << "| #{data['language']} | #{r['label']} | #{r['where_matched']} | #{r['date_groups']} |\n"
    end
  end

  out << "\n## 結論\n\n"
  out << "- **読み取り値の解釈**はドライバ設定で吸収できる。ただし合わせ方は言語ごとに違う\n"
  out << "- **`WHERE` 句と日付集計の差**はどの言語でも吸収できない。サーバー側で確定するため\n"
  out << "- いずれの言語でも、接続直後に `SET time_zone = '+00:00'` でセッションを固定すれば、\n"
  out << "  接続先の設定によらず両方が揃う\n"
  out
end

json_paths = Dir[File.join(options[:input_dir], '*.json')].sort
if json_paths.empty?
  warn "収集済み JSON が見つからない: #{options[:input_dir]}"
  warn '先に probe-go / probe-ruby / probe-python を実行する。'
  exit 1
end

FileUtils.mkdir_p(options[:output_dir])
entries = []
failed = []

json_paths.each do |path|
  data = JSON.parse(File.read(path))
  version = data['schema_version']
  unless version == SCHEMA_VERSION
    warn "#{File.basename(path)}: 未知の schema_version=#{version.inspect}（期待: #{SCHEMA_VERSION}）。読み飛ばす。"
    next
  end

  judgment = evaluate(data)
  entries << [data, judgment]
  out_path = File.join(options[:output_dir], "#{data['language'].downcase}-report.md")
  File.write(out_path, render(data, judgment))

  passed = judgment.values.all?
  failed << data['language'] unless passed
  puts format('%-8s %s  → %s', data['language'], passed ? 'PASS' : 'FAIL', out_path)
  judgment.each { |k, v| puts "           #{v ? '  ok' : '  NG'}  #{k}" } unless passed
end

if entries.empty?
  warn '読み込めた JSON がなかった。'
  exit 1
end

summary_path = File.join(options[:output_dir], 'summary.md')
File.write(summary_path, render_summary(entries))
puts "summary  → #{summary_path}"

if failed.empty?
  puts "\n総合判定: PASS（#{entries.size} 言語）"
  exit 0
else
  warn "\n総合判定: FAIL（#{failed.join(', ')}）"
  exit 1
end
