# frozen_string_literal: true

require 'json'
require 'open3'

# rb/ の道具の共通の部品。AWS CLI のコマンドを呼んで JSON を読む（AWS SDK は使わない。標準のライブラリだけ）。
# port-guard-rollout・sg-ssh-restrict・al2-update の rb/lib.rb と同じところから写し、ssm-setup に要るものだけを残して、
# AWS のエラーのコード（AwsError#code）を足した。
# 認証情報・リージョンは、AWS CLI の設定（AWS_PROFILE・AWS_REGION など）をそのまま使う。Ruby 2.6 以上で動く。
module Tools
  # AWS CLI のコマンドが失敗したとき。code は AWS のエラーのコード（取れなければ nil）
  class AwsError < StandardError
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

  ID_PATTERN = /\Ai-[0-9a-f]{8}([0-9a-f]{9})?\z/.freeze

  module_function

  # aws を呼び、JSON の結果を返す（出力が空なら nil）。失敗したら AwsError
  def aws(*args)
    out, err, status = Open3.capture3({ 'AWS_PAGER' => '' }, 'aws', *args, '--output', 'json')
    raise AwsError, err.strip unless status.success?

    out.strip.empty? ? nil : JSON.parse(out)
  end

  # 標準入力から、インスタンスの ID を 1 行に 1 つ読む（# から後と空の行は無視。2 列目があっても使わない。同じ ID は 1 回だけ）。
  # 形式の誤りは表示して無視する。1 台もなければ終了コード 2 で止める
  def read_ids(io = $stdin)
    ids = io.each_line.map { |line| line.sub(/#.*/, '').split.first }.compact
    invalid = ids.grep_v(ID_PATTERN)
    invalid.each { |value| warn "形式が正しくないので無視する: #{value}" }
    ids = (ids - invalid).uniq
    return ids unless ids.empty?

    warn 'インスタンスの ID がない（標準入力に 1 行 1 つで渡す）'
    exit 2
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

  # PATH にコマンドがあるか
  def command?(name)
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
  end
end
