# frozen_string_literal: true
#
# Step 4 の検証に必要な AWS の状態を収集し、判定器
# （generate_green_verification_report --input-dir）が読むファイル一式を書き出す。
#
# prepare_green_verification.rb（Step 4 の準備）から使う。
#
# **収集だけを行い、判定はしない。**適合・不適合の判断は判定器の --check が行う。
# ここが返すエラーは「収集できなかった」ことだけである（Deployment が無い・AVAILABLE でない等）。
#
# AWS は SDK ではなく AWS CLI を exec する（権限・プロファイル・リージョンの解決が
# 他のスクリプトと同じになる）。JSON は 1 回取って自分で読み、--query で二重に叩かない。
require 'fileutils'
require 'json'
require 'open3'

module GreenState
  class Error < StandardError; end

  # 書き出すファイル名。判定器の --input-dir はこの名前を前提に読む。
  # **名前を変えるときは判定器（Go の generate_green_verification_report の --input-dir）も同時に変える。**
  SOURCE_INSTANCE_FILE   = 'source.json'
  DEPLOYMENT_FILE        = 'deployment.json'
  GREEN_INSTANCE_FILE    = 'green-db-instance.json'
  USER_PARAMETERS_FILE   = 'green-user-parameters.json'
  SYSTEM_PARAMETERS_FILE = 'green-system-parameters.json'
  ALL_PARAMETERS_FILE    = 'green-all-parameters.json'
  REPLICA_LAG_FILE       = 'replica-lag.json'

  # 呼び出し側（シェル）が続きで使う値。
  Result = Struct.new(:deployment_id, :green_instance_id, :green_endpoint)

  module_function

  # region / profile / source_id / target_parameter_group / output_dir は呼び出し側が
  # 設定ファイルから解決して渡す。now はテストで時刻を固定するため。
  def collect(region:, source_id:, target_parameter_group:, output_dir:, profile: '',
              replica_lag_window: 600, now: -> { Time.now })
    begin
      FileUtils.mkdir_p(output_dir)
    rescue SystemCallError => e
      raise Error, "#{output_dir}: 出力先を作れない: #{e.message}"
    end
    call = lambda do |file, *arguments|
      call_aws(region, profile, output_dir, file, arguments)
    end

    # [読み取り] 移行元の ARN を得る。Deployment を source で引き当てるためである。
    source = call.(SOURCE_INSTANCE_FILE, 'rds', 'describe-db-instances', '--db-instance-identifier', source_id)
    source_arn = Array(source['DBInstances']).first.to_h['DBInstanceArn'].to_s
    raise Error, "移行元 #{source_id} の ARN を取得できない" if source_arn.empty?

    # [読み取り] 移行元に対応する Blue/Green Deployment を引き当てる。
    # Deployment ID は設定ファイルに持たず、毎回 AWS から引き当てる（中核ルール）。
    deployments = call.(DEPLOYMENT_FILE, 'rds', 'describe-blue-green-deployments',
                        '--filters', "Name=source,Values=#{source_arn}")
    deployment = Array(deployments['BlueGreenDeployments']).first
    if deployment.nil?
      raise Error, "Blue/Green Deployment not found for #{source_id}\n" \
                   'Step 3（build_green.sh）が未実行か、config の actions.build が pending の可能性がある。'
    end
    status = deployment['Status'].to_s
    raise Error, "Deployment is not AVAILABLE: #{status}" unless status == 'AVAILABLE'

    # Green の識別子は Target ARN の末尾（...:db:<id>）である。
    target = deployment['Target'].to_s
    index = target.rindex(':db:')
    green_id = index ? target[(index + 4)..] : target
    if green_id.empty?
      raise Error, "Deployment #{deployment['BlueGreenDeploymentIdentifier']} の Target から " \
                   "Green の識別子を取れない: #{target.inspect}"
    end

    # [読み取り] Green の状態。エンジン・クラス・パラメータグループの関連付けは
    # 判定器がこのファイルから読んで突き合わせる。
    green = call.(GREEN_INSTANCE_FILE, 'rds', 'describe-db-instances', '--db-instance-identifier', green_id)
    endpoint = Array(green['DBInstances']).first.to_h.dig('Endpoint', 'Address').to_s

    # [読み取り] Green に反映されたパラメータ（Source=user / system / 全件）。
    [
      [USER_PARAMETERS_FILE, %w[--source user]],
      [SYSTEM_PARAMETERS_FILE, %w[--source system]],
      [ALL_PARAMETERS_FILE, []]
    ].each do |file, source_filter|
      call.(file, 'rds', 'describe-db-parameters', '--db-parameter-group-name', target_parameter_group, *source_filter)
    end

    # [読み取り] レプリカ遅延。判定（0 秒であること）は判定器が行う。
    finish = now.call.utc
    start = finish - replica_lag_window
    call.(REPLICA_LAG_FILE, 'cloudwatch', 'get-metric-statistics',
          '--namespace', 'AWS/RDS', '--metric-name', 'ReplicaLag',
          '--dimensions', "Name=DBInstanceIdentifier,Value=#{green_id}",
          '--statistics', 'Maximum', '--period', '60',
          '--start-time', rfc3339(start), '--end-time', rfc3339(finish))

    Result.new(deployment['BlueGreenDeploymentIdentifier'].to_s, green_id, endpoint)
  end

  # AWS CLI を 1 回呼び、応答 JSON を file へ保存して解析結果を返す。
  # **保存するのは生の応答である。**
  def call_aws(region, profile, output_dir, file, arguments)
    command = ['aws', '--region', region]
    command += ['--profile', profile] unless profile.to_s.empty?
    command += arguments + ['--output', 'json']
    stdout, stderr, status = Open3.capture3(*command)
    unless status.success?
      called = arguments.join(' ')
      reason = status.exitstatus ? "exit status #{status.exitstatus}" : status.to_s
      message = "aws #{called} failed: #{reason}"
      message += ": #{stderr.strip}" unless stderr.empty?
      raise Error, message
    end
    path = File.join(output_dir, file)
    begin
      File.write(path, stdout)
    rescue SystemCallError => e
      raise Error, "#{path}: 書き込めない: #{e.message}"
    end
    begin
      JSON.parse(stdout)
    rescue JSON::ParserError => e
      raise Error, "aws #{arguments.join(' ')} の応答を解析できない: #{e.message}"
    end
  end

  def rfc3339(time)
    time.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  end
end
