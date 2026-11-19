# frozen_string_literal: true

require 'json'
require 'open3'

# AWS CLI のコマンドを呼んで、JSON の結果を読む（AWS SDK は使わない。標準のライブラリだけ）。
# 汎用の部品（Infrastructure 層）だけを置く。どの API をどう読むかなど、AWS の機能の仕様に紐づくものは、
# 重複があっても各コマンドの側に書く。docs/ec2/ssm-setup/rb/lib/aws_cli.rb から写した（このフォルダの中で完結させるため）。
# プロファイルとリージョンは configure で指定できる（各コマンドの --profile・--region。lib/cli.rb の parse_options が呼ぶ）。
# 指定しなければ、AWS CLI の設定（AWS_PROFILE・AWS_REGION など）をそのまま使う。Ruby 2.6 以上で動く。
module AwsCli
  # AWS CLI のコマンドが失敗したとき。code は AWS のエラーのコード（取れなければ nil）
  class Error < StandardError
    attr_reader :code

    def initialize(message)
      super
      @code = message[/An error occurred \(([^)]+)\)/, 1]
    end

    # 表示用の 1 行（最後の行）
    def summary
      message.lines.last.to_s.strip
    end
  end

  @global_args = [] # すべての呼び出しに付ける --profile・--region
  @region = nil

  module_function

  # すべての呼び出しに付けるプロファイルとリージョン（nil なら付けない）
  def configure(profile: nil, region: nil)
    @global_args = []
    @global_args += ['--profile', profile] if profile
    @global_args += ['--region', region] if region
    @region = region
  end

  # aws を呼び、JSON の結果を返す（出力が空なら nil）。失敗したら Error
  def run(*args)
    out, err, status = Open3.capture3({ 'AWS_PAGER' => '' }, 'aws', *args, '--output', 'json', *@global_args)
    raise Error, err.strip unless status.success?

    out.strip.empty? ? nil : JSON.parse(out)
  end

  # 使われるリージョン（--region、AWS_REGION・AWS_DEFAULT_REGION、AWS CLI の設定の順。取れなければ nil）
  def region
    return @region if @region

    env = ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION']
    return env unless env.to_s.empty?

    profile_args = @global_args.each_slice(2).select { |key, _| key == '--profile' }.flatten
    out, _err, status = Open3.capture3('aws', 'configure', 'get', 'region', *profile_args)
    status.success? && !out.strip.empty? ? out.strip : nil
  end

  # aws のコマンドが PATH にあるか
  def available?
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, 'aws')) }
  end
end
