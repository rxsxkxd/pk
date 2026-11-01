# frozen_string_literal: true

require 'io/wait'
require 'net/http'
require 'openssl'
require 'socket'
require_relative 'lib'

# port-guard-rollout の rb/ の道具だけで使う部品（ssm-setup にはない、このフェーズのもの）。
# インスタンスに送るものは、Python 版・sh 版と共用の port-guard-rollout/remote/ から読む。
module PortGuard
  REMOTE_DIR = File.expand_path('../remote', __dir__)
  BACKUP_PURPOSE = 'port-guard-rollout-backup'
  BACKUP_MAX_AGE = 12 * 60 * 60

  module_function

  def remote_file(*names)
    names.map { |name| File.read(File.join(REMOTE_DIR, name)) }.join("\n")
  end

  # バックアップの確認: タグ Purpose・SourceInstanceId・BackupLabel が合い、作成が終わっていて、12 時間以内の AMI がある台と、ない台
  def check_backups(ids, label)
    ids.partition do |id|
      ok = backup_available?(id, label)
      puts "バックアップなし  #{id}  （「#{label}」の、12 時間以内の使えるバックアップ（AMI）がない）" unless ok
      ok
    end
  end

  def backup_available?(id, label)
    since = (Time.now.utc - BACKUP_MAX_AGE).strftime('%Y-%m-%dT%H:%M:%S')
    images = Tools.aws('ec2', 'describe-images', '--owners', 'self', '--filters',
                       "Name=tag:Purpose,Values=#{BACKUP_PURPOSE}", "Name=tag:SourceInstanceId,Values=#{id}",
                       "Name=tag:BackupLabel,Values=#{label}", 'Name=state,Values=available')['Images']
    images.any? { |image| image['CreationDate'] >= since }
  rescue Tools::AwsError
    false
  end

  # 送った結果の "PG <キー>=<値>" の行（同じキーは最後の値）
  def values(result)
    output(result).scan(/^PG (\w+)=(.*)$/).to_h
  end

  # 送った結果の "PG blocked=<理由>" の行（インスタンスの側の確認で止まった理由）
  def blocked_reasons(result)
    output(result).scan(/^PG blocked=(.*)$/).flatten
  end

  # 送った結果が失敗なら、その説明（成功なら nil）
  def failure(result)
    return '結果が返らない（待ちきれない）' unless result
    return nil if result['Status'] == 'Success'

    step = output(result).scan(/^PGSTEP (.*)$/).flatten.last || '（開始前）'
    detail = result['StandardErrorContent'].to_s.lines.last.to_s.strip
    "「#{step}」で #{result['Status']}（#{detail.empty? ? 'エラーの出力なし' : detail}）"
  end

  # SSM の Run Command で送る。送れなければ、失敗の結果（Status が NotSent）として返す
  def run_script(id, script)
    Tools.run_ssm(id, script)
  rescue Tools::AwsError => e
    { 'Status' => 'NotSent', 'StandardErrorContent' => e.message }
  end

  def address_of(id)
    instance = Tools.aws('ec2', 'describe-instances', '--instance-ids', id).dig('Reservations', 0, 'Instances', 0)
    instance['PublicIpAddress'] || instance['PrivateIpAddress']
  end

  # 相手が応答するか（TCP の接続だけでは、途中の転送の仕組みが受け付けてしまうことがあるので、応答まで見る）
  def responds?(ip, port)
    return ssh_responds?(ip) if port == '22'

    Net::HTTP.start(ip, port.to_i, use_ssl: port == '443', verify_mode: OpenSSL::SSL::VERIFY_NONE,
                                   open_timeout: 5, read_timeout: 5, ssl_timeout: 5) { |http| http.head('/') }
    true
  rescue StandardError
    false
  end

  def ssh_responds?(ip)
    Socket.tcp(ip, 22, connect_timeout: 5) do |socket|
      socket.wait_readable(5) && socket.readpartial(4).start_with?('SSH-')
    end
  rescue StandardError
    false
  end

  def output(result)
    result.to_h['StandardOutputContent'].to_s
  end
end
