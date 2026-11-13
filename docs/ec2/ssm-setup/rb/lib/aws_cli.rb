# frozen_string_literal: true

require 'json'
require 'open3'

# AWS CLI のコマンドを呼んで、JSON の結果を読む（AWS SDK は使わない。標準のライブラリだけ）。
# 汎用の部品（Infrastructure 層）だけを置く。どの API をどう読むかなど、AWS の機能の仕様に紐づくものは、
# 重複があっても各コマンドの側に書く。
# port-guard-rollout・sg-ssh-restrict・al2-update の rb/lib.rb と同じところから写し、AWS のエラーのコード（Error#code）を足した。
# 認証情報・リージョンは、AWS CLI の設定（AWS_PROFILE・AWS_REGION など）をそのまま使う。Ruby 2.6 以上で動く。
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

  module_function

  # aws を呼び、JSON の結果を返す（出力が空なら nil）。失敗したら Error
  def run(*args)
    out, err, status = Open3.capture3({ 'AWS_PAGER' => '' }, 'aws', *args, '--output', 'json')
    raise Error, err.strip unless status.success?

    out.strip.empty? ? nil : JSON.parse(out)
  end

  # aws のコマンドが PATH にあるか
  def available?
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, 'aws')) }
  end
end
