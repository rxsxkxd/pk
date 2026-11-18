# frozen_string_literal: true

require 'optparse'
require_relative 'aws_cli'

# コマンドの入出力の汎用の部品（Infrastructure 層）: オプションの読み込み、端末での確認、使い方の誤りの扱い。
# AWS の機能の仕様に紐づくものは置かない。docs/ec2/ssm-setup/rb/lib/cli.rb から、要るものだけを写した。
module Cli
  ENVIRONMENTS = %w[development staging production].freeze
  ID_PATTERN = /\Ai-[0-9a-f]{8}([0-9a-f]{9})?\z/.freeze
  # このフォルダ（rule-apply-via-ssm/）
  BASE_DIR = File.expand_path('../..', __dir__)

  module_function

  # 端末から y を受けたら true、ほかは false。端末がなければ nil
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

  # OptionParser でオプションを読む（ブロックでコマンドのオプションを定義する）。誤りなら終了コード 2。
  # どのコマンドにも --profile・--region を足し、AwsCli に渡す（options には入れない）
  def parse_options(options = {})
    aws = {}
    OptionParser.new do |parser|
      yield parser, options
      parser.on('--profile NAME', 'AWS CLI のプロファイル') { |value| aws[:profile] = value }
      parser.on('--region NAME', 'AWS のリージョン') { |value| aws[:region] = value }
    end.parse!
    AwsCli.configure(**aws)
    options
  rescue OptionParser::ParseError => e
    usage_error(e.message)
  end

  # 既定のインスタンスの一覧ファイル（instance-lists/<環境>.tsv）
  def default_list_path(environment)
    File.join(BASE_DIR, 'instance-lists', "#{environment}.tsv")
  end
end
