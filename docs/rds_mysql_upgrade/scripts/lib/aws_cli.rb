# frozen_string_literal: true
#
# AWS CLI の呼び出し（Ruby 版スクリプト共通）。
#
# **SDK は使わず AWS CLI を exec する。**シェル版と同じコマンドを同じ引数で叩くため、
# 権限・プロファイル・リージョンの解決が完全に同じになる。gem の追加導入も要らない。
#
# 変更操作を行う呼び出しには、シェル版と同様に `# [変更]` のコメントを付ける。
require 'json'
require 'open3'

class AwsCli
  class Error < StandardError; end

  def initialize(region:, profile: '')
    @base = ['aws', '--region', region]
    @base += ['--profile', profile] unless profile.to_s.empty?
  end

  # コマンドの表示用。案内メッセージへ載せる。
  def command_prefix
    @base.join(' ')
  end

  # 実行して標準出力を返す。失敗したらそのまま落とす。
  def run(*args)
    stdout, stderr, status = Open3.capture3(*@base, *args)
    raise Error, "aws #{args.join(' ')} が失敗した: #{stderr.strip}" unless status.success?
    stdout
  end

  # JSON で受け取り、そのままファイルへも保存する。
  # **保存するのは生の応答である。**後段が読み直せるようにするため。
  def run_json(*args, save_to: nil)
    output = run(*args, '--output', 'json')
    File.write(save_to, output) if save_to
    JSON.parse(output)
  end
end
