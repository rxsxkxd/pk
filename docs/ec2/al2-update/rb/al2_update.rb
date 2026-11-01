# frozen_string_literal: true

require 'open3'
require 'shellwords'
require_relative 'lib'

# al2-update の rb/ の道具で共用する部品（ssm-setup にはない、このフェーズのもの）。
# 何を更新の対象にするかの指定、インスタンスに送るスクリプトの組み立て（al2-update/remote/ から読む）、パッケージの見分け方。
module AL2Update
  REMOTE_DIR = File.expand_path('../remote', __dir__)
  # Run Command の出力は 24,000 文字で切れる。送るスクリプトの最後にこの行を出させ、切れていないかを確かめる
  OUTPUT_END = "\necho 'PG output_end=yes'\n"
  # いつも更新から除くパッケージ。SSM Agent は、Run Command で動いている yum が自分を更新すると、
  # 途中で SSM Agent が再起動して結果が返らなくなることがある（SSM Agent の更新は AWS-UpdateSSMAgent で別に行う）
  ALWAYS_EXCLUDED = %w[amazon-ssm-agent].freeze
  # 既定で更新から除くパッケージ（Apache。過去に、更新で mod_ssl のリンク先の libssl が変わった）。--include-apache で外す
  APACHE_PATTERNS = %w[httpd* mod_*].freeze
  # 更新に含まれたら目立たせるパッケージ（パターン → 理由）。除くかどうかとは別
  ATTENTION = {
    'httpd*' => 'Apache の本体（Passenger とアプリが中で動く）',
    'mod_*' => 'Apache のモジュール（mod_ssl はリンク先の libssl が変わることがある）',
    'apr*' => 'Apache が使う部品',
    'openssl*' => 'OpenSSL（mod_ssl と Ruby の openssl が使う。動いているプロセスは再起動まで古いものを使う）',
    'kernel*' => 'カーネル（再起動するまで効かない）',
    'glibc*' => 'glibc（動いているプロセスは再起動まで古いものを使う）'
  }.freeze

  # 何を更新の対象にするか（scope: security か all）、除くパッケージのパターン、アプリの応答を見る URL
  Settings = Struct.new(:scope, :excludes, :health_url, keyword_init: true)

  module_function

  # rb/check.rb と rb/update.rb で共通の指定（同じ指定で確かめてから更新できるように、両方に同じものを持たせる）
  def define_update_options(parser, options)
    parser.on('--all', '全部の更新を対象にする（既定はセキュリティの更新だけ）') { options[:scope] = 'all' }
    parser.on('--exclude PATTERN', '更新から除くパッケージ（yum の --exclude と同じパターン。何回でも）') do |value|
      options[:excludes] << value
    end
    parser.on('--include-apache', "既定で除く Apache（#{APACHE_PATTERNS.join(' ')}）も更新の対象にする") do
      options[:include_apache] = true
    end
    parser.on('--health-url URL', 'インスタンスの中から応答を見る URL（既定 http://127.0.0.1/。空にすると見ない）') do |value|
      options[:health_url] = value
    end
  end

  # rb/backup.rb と rb/update.rb で共通の --check-only・--yes（action は、行うことの説明）
  def define_run_options(parser, options, action)
    parser.on('--check-only', "確かめて表示するだけ（#{action}は行わない）") { options[:check_only] = true }
    parser.on('--yes', "#{action}を試行するかを確かめずに進める") { options[:yes] = true }
  end

  def default_update_options
    { scope: 'security', excludes: [], include_apache: false, health_url: 'http://127.0.0.1/' }
  end

  def settings_from(options)
    excludes = ALWAYS_EXCLUDED + (options[:include_apache] ? [] : APACHE_PATTERNS) + options[:excludes]
    Settings.new(scope: options[:scope], excludes: excludes.uniq, health_url: options[:health_url])
  end

  def describe_settings(settings)
    scope = settings.scope == 'all' ? '全部の更新' : 'セキュリティの更新だけ'
    excludes = settings.excludes.empty? ? 'なし' : settings.excludes.join(' ')
    "対象 #{scope}、除くパッケージ #{excludes}、アプリの応答 #{settings.health_url.to_s.empty? ? '見ない' : settings.health_url}"
  end

  # 更新の確認で送るもの: 渡す値（AU_*）、更新してよいかの確認、今の状態、更新される予定のパッケージ（長い一覧を最後に）
  def inspect_script(settings)
    prelude(settings) + remote_file('preflight.sh', 'status.sh', 'check-updates.sh') + OUTPUT_END
  end

  # 更新で送るもの: 渡す値、更新してよいかの確認（送る直前にもう一度）、更新、更新の後の状態、変わったパッケージの一覧
  def update_script(settings, run_id)
    prelude(settings, 'AU_RUN_ID' => run_id) +
      remote_file('preflight.sh', 'update.sh', 'status.sh', 'update-report.sh') + OUTPUT_END
  end

  def prelude(settings, extra = {})
    values = { 'AU_SCOPE' => settings.scope, 'AU_EXCLUDE' => settings.excludes.join(' '),
               'AU_HEALTH_URL' => settings.health_url.to_s }.merge(extra)
    values.map { |key, value| "#{key}=#{Shellwords.escape(value)}\n" }.join
  end

  def remote_file(*names)
    names.map { |name| File.read(File.join(REMOTE_DIR, name)) }.join("\n")
  end

  # SSM の Run Command で送る。送れなければ、失敗の結果（Status が NotSent）として返す
  def run_script(id, script)
    Tools.run_ssm(id, script)
  rescue Tools::AwsError => e
    { 'Status' => 'NotSent', 'StandardErrorContent' => e.message }
  end

  # パターンに合うか（yum の --exclude と同じく、名前か「名前.アーキテクチャ」に合えばよい）
  def matches?(name_arch, patterns)
    name = name_arch.sub(/\.[^.]+\z/, '')
    patterns.any? { |pattern| File.fnmatch(pattern, name) || File.fnmatch(pattern, name_arch) }
  end

  # 目立たせる理由（当てはまらなければ nil）
  def attention_reason(name_arch)
    ATTENTION.each { |pattern, reason| return reason if matches?(name_arch, [pattern]) }
    nil
  end

  # パッケージの行の一覧から、注意が要るものの「名前.アーキテクチャ」を選ぶ
  def attention_names(entries)
    entries.map { |entry| entry.split.first }.select { |name_arch| attention_reason(name_arch) }
  end

  # パッケージの 1 行（"<名前>.<アーキテクチャ> <版>"）に、注意が要る理由を添える
  def with_attention(entry)
    reason = attention_reason(entry.split.first)
    reason ? "#{entry}  ← 注意: #{reason}" : entry
  end

  # 前提の確認: AWS CLI が使えるか（使えなければ、終了コード 2 で止める）
  def require_aws_cli
    Open3.capture3('aws', '--version')
  rescue SystemCallError
    usage_error('aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）')
  end

  # 入力・前提の問題: 理由を出して、終了コード 2 で止める
  def usage_error(message)
    warn message
    exit 2
  end
end
