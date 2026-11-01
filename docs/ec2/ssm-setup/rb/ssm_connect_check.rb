#!/usr/bin/env ruby
# frozen_string_literal: true

#   ruby rb/ssm_connect_check.rb [--ok-out ok.txt] [--ng-out connect-ng.txt] [--timeout 60] < enabled.txt
require 'optparse'
require_relative 'lib'

# SSM で実際に入れるかを、Run Command で echo を 1 回だけ流して確かめる（設定は変えない。コマンドの履歴は AWS の側に残る）。
# 事前の確認（状態・ロール・登録）はしない。rb/ssm_check.rb の --ok-out（SSM 有効の台）を渡す想定。
# 公開のメソッドが流れの大枠、private の下がヘルパ。
class SsmConnectCheck
  MARKER = 'PG ssm_connect_check=ok'
  HINT = 'ssmmessages・ec2messages への送信の 443 番、作業者の権限（ssm:SendCommand）、SSM Agent の版を見る'

  def initialize(ok_out:, ng_out:, timeout:)
    @ok_out = ok_out
    @ng_out = ng_out
    @timeout = timeout
  end

  # 流れ: 1 台ずつ echo を流す → 一覧を書き出す → 結果を表示する
  def run(ids)
    problems = connect_all(ids)
    write_lists(problems)
    print_summary(problems)
    problems.values.none? ? 0 : 1
  end

  # インスタンスの ID → 入れない理由（入れれば nil）
  def connect_all(ids)
    ids.to_h { |id| [id, connect(id)] }
  end

  # 一覧を書き出す（--ok-out はフェーズ 2 へ。--ng-out は直した後に、もう一度この道具へ）
  def write_lists(problems)
    connected, failed = problems.keys.partition { |id| problems[id].nil? }
    write_list(@ok_out, '# SSM で実際に入れた台（フェーズ 2 の標準入力に渡せる）', connected)
    write_list(@ng_out, "# SSM で入れなかった台（直した後に、もう一度この道具に渡せる）。#{HINT}",
               failed.map { |id| "#{id}  # #{problems[id]}" })
  end

  def print_summary(problems)
    puts "== 結果: 入れる #{problems.values.count(&:nil?)} 台、入れない #{problems.values.compact.size} 台"
  end

  private

  # 1 台に echo を流して表示する。入れなければ理由を返す（入れれば nil）
  def connect(id)
    problem = connection_problem(id)
    puts problem ? "入れない  #{id}  #{problem}" : "入れる    #{id}"
    problem
  end

  def connection_problem(id)
    result = Tools.run_ssm(id, "echo '#{MARKER}'", tries: (@timeout / 3.0).ceil)
    return "#{@timeout} 秒で結果が返らない" unless result
    return nil if result['StandardOutputContent'].to_s.include?(MARKER)

    "コマンドが #{result['Status']} で終わった"
  rescue Tools::AwsError => e
    "コマンドを送れない（#{e.message.lines.last.to_s.strip}）"
  end

  def write_list(path, header, lines)
    File.write(path, [header, *lines].map { |line| "#{line}\n" }.join)
  end
end

def parse_options
  options = { ok_out: File::NULL, ng_out: File::NULL, timeout: 60 }
  OptionParser.new do |o|
    o.on('--ok-out PATH') { |v| options[:ok_out] = v }
    o.on('--ng-out PATH') { |v| options[:ng_out] = v }
    o.on('--timeout SECONDS', Integer) { |v| options[:timeout] = v }
  end.parse!
  options
end

exit SsmConnectCheck.new(**parse_options).run(Tools.read_ids)
