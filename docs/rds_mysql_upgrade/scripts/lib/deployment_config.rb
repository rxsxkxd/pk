# frozen_string_literal: true
#
# 実行設定 YAML（config/blue-green/<環境>.deployment.yml）の読み取り。
#
# **設定の読み取りはこのファイルだけが行う。**Ruby からは require して使い、
# シェルからはコマンドとして呼んで `NAME='値'` の代入行を受け取る。
# YAML は psych（Ruby 標準ライブラリ）で直接読むので、jq も追加パッケージも要らない。
#
# --- Ruby から ---------------------------------------------------------------
#   require_relative 'lib/deployment_config'
#   config = DeploymentConfig.load(path)
#   region = config.required('aws_region')
#   svc    = config.service('example-service')
#   id     = svc.required('source_db_instance_identifier')
#   build  = svc.optional('actions.build', 'pending')     # ドット区切りで入れ子を辿る
#
# --- シェルから ---------------------------------------------------------------
#   ruby deployment_config.rb vars <config> <service> 変数名=種別:パス[=既定値] ...
#
#     種別   required  空・未定義なら失敗（`<パス> が未定義である`）
#            optional  空・未定義なら既定値（省略時は空文字）
#            flag      真偽値。true / "true" なら "true"、それ以外は "false"
#     パス   service.<キー>  … services.<サービス名> 配下（ドットで入れ子を辿る）
#            <キー>          … トップレベル
#
#   例:
#     config_vars=$(ruby "$(dirname "$0")/lib/deployment_config.rb" vars "$config" "$service" \
#       build=optional:service.actions.build=pending \
#       source_id=required:service.source_db_instance_identifier \
#       config_region=required:aws_region)
#     eval "$config_vars"
#
#   ruby deployment_config.rb mysql-verification <config> <service>
#     mysql_verification を検証し、MYSQL_VERIFY_* の代入行を出す（下の mysql_verification を参照）。
#
# **eval "$(ruby deployment_config.rb ...)" と 1 行で書かない。**その形だと読み取りが
# 失敗しても終了コードが eval のものに化け、set -e をすり抜けて
# 「変数が空のまま先へ進む」ことになる。いったん変数へ受けてから eval する。
#
# 失敗時は理由を stderr へ 1 行出して終了コード 1、使い方の誤りは 2。
require 'yaml'

class DeploymentConfig
  # 設定の読み取りに失敗したときに投げる。呼び出し側は rescue して exit する。
  class Error < StandardError; end

  # mysql_verification.auth_method の有効な値。
  # secrets_manager / iam は対応しない（不正な値として拒否する）。
  AUTH_METHODS = %w[parameter_store plaintext prompt].freeze

  # safe_load はエイリアス・任意クラスの復元を許さない（設定ファイルは素のマッピングだけ）。
  def self.load(path)
    document = YAML.safe_load(File.read(path))
    raise Error, "#{path}: YAML がマッピングではない" unless document.is_a?(Hash)
    new(document, '')
  rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
    raise Error, "#{path}: YAML を読み込めなかった: #{e.message}"
  rescue Psych::SyntaxError => e
    raise Error, "#{path}: YAML を解析できなかった: #{e.message}"
  end

  def initialize(document, prefix)
    @document = document
    @prefix = prefix
  end

  # 必須項目。空・未定義なら文脈付きで落とす。
  def required(key)
    value = lookup(key)
    raise Error, "#{qualify(key)} が未定義である" if blank?(value)
    value.to_s
  end

  # 任意項目。未定義なら既定値を使う。
  def optional(key, fallback = '')
    value = lookup(key)
    blank?(value) ? fallback : value.to_s
  end

  # 真偽値。YAML の true と文字列 "true" だけを真とし、未定義は偽に倒す。
  def flag(key)
    value = lookup(key)
    value == true || value.to_s == 'true'
  end

  # services.<名前> を取り出す。
  def service(name)
    services = @document['services']
    entry = services.is_a?(Hash) ? services[name] : nil
    raise Error, "services.#{name} が未定義である" unless entry.is_a?(Hash)
    DeploymentConfig.new(entry, "services.#{name}")
  end

  # サービスの mysql_verification を検証し、MYSQL_VERIFY_* を返す。AWS API は呼ばない。
  # `environment`（トップレベル）が要るため、トップレベルの設定に対して呼ぶ。
  #
  # 検証（enabled: true のときだけ行う）:
  #   - auth_method は AUTH_METHODS のいずれか（既定 prompt）
  #   - parameter_store はユーザー名も秘匿側へ置く。parameter_name と
  #     user_parameter_name の両方が必須で、config の user は使わない
  #   - 秘匿側を持たない plaintext / prompt では config の user が必須
  #   - plaintext は設定ファイルが Git 追跡対象であるため、production では拒否する
  def mysql_verification(service_name)
    environment = optional('environment')
    m = service(service_name)
    enabled = m.flag('mysql_verification.enabled')
    auth = m.optional('mysql_verification.auth_method', 'prompt')
    validate_mysql_verification(m, environment, auth) if enabled
    {
      'MYSQL_VERIFY_ENABLED' => enabled.to_s,
      'MYSQL_VERIFY_USER' => m.optional('mysql_verification.user'),
      'MYSQL_VERIFY_AUTH' => auth,
      'MYSQL_VERIFY_PARAMETER_NAME' => m.optional('mysql_verification.parameter_name'),
      'MYSQL_VERIFY_USER_PARAMETER_NAME' => m.optional('mysql_verification.user_parameter_name'),
      'MYSQL_VERIFY_PLAINTEXT' => m.optional('mysql_verification.password'),
      'MYSQL_VERIFY_SSL_CA' => m.optional('mysql_verification.ssl_ca'),
      'MYSQL_VERIFY_PORT' => m.optional('mysql_verification.port', '3306'),
    }
  end

  private

  # ドット区切りのキーで入れ子を辿る。途中がマッピングでなければ未定義として扱う。
  def lookup(key)
    key.split('.').reduce(@document) do |node, part|
      node.is_a?(Hash) ? node[part] : nil
    end
  end

  def blank?(value)
    value.nil? || value.to_s.empty?
  end

  def qualify(key)
    @prefix.empty? ? key : "#{@prefix}.#{key}"
  end

  def validate_mysql_verification(m, environment, auth)
    unless AUTH_METHODS.include?(auth)
      raise Error, "mysql_verification.auth_method が不正です: #{auth}（有効な値: #{AUTH_METHODS.join(', ')}）"
    end
    if auth != 'parameter_store' && m.optional('mysql_verification.user').empty?
      raise Error, "auth_method: #{auth} には mysql_verification.user が必要です"
    end
    if auth == 'plaintext' && environment == 'production'
      raise Error, 'auth_method: plaintext は production では使用できません。parameter_store を使ってください'
    end
    needed = { 'parameter_store' => %w[parameter_name user_parameter_name], 'plaintext' => %w[password] }
    missing = needed.fetch(auth, []).find { |key| m.optional("mysql_verification.#{key}").empty? }
    raise Error, "auth_method: #{auth} には mysql_verification.#{missing} が必要です" if missing
  end
end

# --- コマンドとして呼ばれたとき ------------------------------------------------
if $PROGRAM_NAME == __FILE__
  # シェルの単一引用符で囲む。値に ' があれば '\'' へ置き換える（jq の @sh と同じ）。
  def shell_quote(value)
    "'#{value.to_s.gsub("'", %q('\\\\''))}'"
  end

  def print_assignments(pairs)
    pairs.each { |name, value| puts "#{name}=#{shell_quote(value)}" }
  end

  def usage_error(message)
    warn message
    warn 'Usage: deployment_config.rb vars <config> <service> 変数名=種別:パス[=既定値] ...'
    warn '       deployment_config.rb mysql-verification <config> <service>'
    exit 2
  end

  VARIABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze
  SPEC = /\A(?<name>[^=]+)=(?<kind>required|optional|flag):(?<path>[^=]+)(?:=(?<fallback>.*))?\z/m.freeze

  command, config_path, service_name, *specs = ARGV
  usage_error('引数が足りない') if command.nil? || config_path.nil? || service_name.nil?

  begin
    case command
    when 'vars'
      usage_error('取り出す項目を 1 つ以上指定する') if specs.empty?
      # 宣言の誤りは設定を読む前に検出する（設定ファイルの問題と混同しないため）。
      parsed = specs.map do |spec|
        m = SPEC.match(spec) or usage_error("項目の宣言を解釈できない: #{spec}")
        usage_error("変数名が不正: #{m[:name]}") unless VARIABLE_NAME.match?(m[:name])
        usage_error("既定値を持てるのは optional だけ: #{spec}") if m[:fallback] && m[:kind] != 'optional'
        m
      end
      config = DeploymentConfig.load(config_path)
      service = nil
      values = parsed.map do |m|
        source, key = if m[:path].start_with?('service.')
                        # サービスは使うときにだけ引く（トップレベルだけを読む呼び出しでは不要）。
                        [service ||= config.service(service_name), m[:path].delete_prefix('service.')]
                      else
                        [config, m[:path]]
                      end
        value = case m[:kind]
                when 'required' then source.required(key)
                when 'optional' then source.optional(key, m[:fallback] || '')
                when 'flag' then source.flag(key).to_s
                end
        [m[:name], value]
      end
      print_assignments(values)
    when 'mysql-verification'
      print_assignments(DeploymentConfig.load(config_path).mysql_verification(service_name))
    else
      usage_error("未知のコマンド: #{command}")
    end
  rescue DeploymentConfig::Error => e
    warn e.message
    exit 1
  end
end
