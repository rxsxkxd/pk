# frozen_string_literal: true

require 'optparse'
require_relative 'aws_cli'

# コマンドの入出力の汎用の部品（Infrastructure 層）: 標準入力からの一覧の読み込み、端末での確認、オプションの読み込み、
# 使い方の誤りの扱い、一覧の書き出し。AWS の機能の仕様に紐づくものは置かない。
module Cli
  ID_PATTERN = /\Ai-[0-9a-f]{8}([0-9a-f]{9})?\z/.freeze

  module_function

  # 標準入力から、インスタンスの ID を 1 行に 1 つ読む（# から後と空の行は無視。2 列目があっても使わない。同じ ID は 1 回だけ）。
  # 形式の誤りは表示して無視する。1 台もなければ終了コード 2 で止める
  def read_ids(io = $stdin)
    ids = io.each_line.map { |line| line.sub(/#.*/, '').split.first }.compact
    invalid = ids.grep_v(ID_PATTERN)
    invalid.each { |value| warn "形式が正しくないので無視する: #{value}" }
    ids = (ids - invalid).uniq
    return ids unless ids.empty?

    usage_error('インスタンスの ID がない（標準入力に 1 行 1 つで渡す）')
  end

  # 端末から y を受けたら true、ほかは false。端末がなければ nil
  # （標準入力はインスタンスの一覧に使っているため、/dev/tty から読む）
  def ask(question)
    File.open('/dev/tty', 'r+') do |tty|
      tty.print("#{question} [y/N]: ")
      tty.gets.to_s.strip.downcase.start_with?('y')
    end
  rescue SystemCallError
    nil
  end

  # 入力・前提の問題: 理由を出して、終了コード 2 で止める
  def usage_error(message)
    warn message
    exit 2
  end

  # AWS CLI がなければ、終了コード 2 で止める
  def require_aws_cli
    usage_error('aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）') unless AwsCli.available?
  end

  # OptionParser でオプションを読む（ブロックでオプションを定義する）。誤りなら終了コード 2
  def parse_options(options = {})
    OptionParser.new { |parser| yield parser, options }.parse!
    options
  rescue OptionParser::ParseError => e
    usage_error(e.message)
  end

  # 設定を変えるコマンドの --check-only・--yes（action は、行うことの説明）
  def define_run_options(parser, options, action)
    parser.on('--check-only', "確かめて表示するだけ（#{action}は行わない）") { options[:check_only] = true }
    parser.on('--yes', "#{action}を試行するかを確かめずに進める") { options[:yes] = true }
  end

  # 一覧を書き出す（1 行目は説明の # の行）
  def write_list(path, header, lines)
    File.write(path, (["# #{header}"] + lines).map { |line| "#{line}\n" }.join)
  end
end
