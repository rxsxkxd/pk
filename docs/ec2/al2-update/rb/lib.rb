# frozen_string_literal: true

require 'json'
require 'open3'

# rb/ の道具の共通の部品（port-guard-rollout・sg-ssh-restrict・al2-update の rb/lib.rb は、もとは同じもの。ssm-setup の rb/lib.rb も同じところから写して、要るものだけにした）。AWS CLI のコマンドを呼んで JSON を読む（AWS SDK は使わない。標準のライブラリだけ）。
# 認証情報・リージョンは、AWS CLI の設定（AWS_PROFILE・AWS_REGION など）をそのまま使う。Ruby 2.6 以上で動く。
module Tools
  class AwsError < StandardError; end

  ID_PATTERN = /\Ai-[0-9a-f]{8}([0-9a-f]{9})?\z/.freeze
  WAITING = %w[Pending InProgress Delayed].freeze

  module_function

  # aws を呼び、JSON の結果を返す（出力が空なら nil）。失敗したら AwsError
  def aws(*args)
    out, err, status = Open3.capture3({ 'AWS_PAGER' => '' }, 'aws', *args, '--output', 'json')
    raise AwsError, err.strip unless status.success?

    out.strip.empty? ? nil : JSON.parse(out)
  end

  # 標準入力から、インスタンスの ID を 1 行に 1 つ読む（# から後と空の行は無視。2 列目があっても使わない）
  def read_ids(io = $stdin)
    ids = io.each_line.map { |line| line.sub(/#.*/, '').split.first }.grep(ID_PATTERN).uniq
    return ids unless ids.empty?

    warn 'インスタンスの ID がない（標準入力に 1 行 1 つで渡す）'
    exit 2
  end

  # 端末から y を受けたら true（標準入力はインスタンスの一覧に使っているため、/dev/tty から読む）
  def ask(question)
    File.open('/dev/tty', 'r+') do |tty|
      tty.print("#{question} [y/N]: ")
      tty.gets.to_s.strip == 'y'
    end
  rescue SystemCallError
    false
  end

  # SSM の Run Command で、スクリプトを root として実行する。結果（get-command-invocation）を返す。待ちきれなければ nil
  def run_ssm(id, script, tries: 320)
    command_id = send_script(id, script)
    tries.times do
      sleep 3
      result = fetch_command_result(command_id, id)
      return result if result && !WAITING.include?(result['Status'])
    end
    nil
  end

  # スクリプトは base64 にして 1 行のコマンドとして送る（引用符や改行で壊れないように）
  def send_script(id, script)
    parameters = { commands: ["echo #{[script].pack('m0')} | base64 -d | bash"], executionTimeout: ['900'] }
    aws('ssm', 'send-command', '--instance-ids', id, '--document-name', 'AWS-RunShellScript',
        '--comment', File.basename($PROGRAM_NAME), '--parameters', parameters.to_json).dig('Command', 'CommandId')
  end

  # 送った直後は、まだ結果の記録がない（nil を返して待ち続ける）
  def fetch_command_result(command_id, id)
    aws('ssm', 'get-command-invocation', '--command-id', command_id, '--instance-id', id)
  rescue AwsError
    nil
  end

  # run_ssm の中だけで使う補助は、外（Tools.send_script など）から呼べないようにする
  private_class_method :send_script, :fetch_command_result
end
