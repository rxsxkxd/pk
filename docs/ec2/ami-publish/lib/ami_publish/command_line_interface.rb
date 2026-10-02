# frozen_string_literal: true

module AmiPublish
  # コマンドライン引数を解釈してサブコマンドを実行し、終了コードを返す。
  #   0 成功 / 1 ステップが望ましい状態に到達できなかった / 2 使い方・設定値の誤り / 3 想定外の AWS エラー
  class CommandLineInterface
    SUBCOMMANDS = %w[run plan rollback].freeze
    VERIFIED_VALUES = %w[manual automated].freeze
    # 終了コード 3 にする AWS 関連のエラー（API のエラーに加え、認証情報がない・接続できない場合）
    AWS_ERRORS = [Aws::Errors::ServiceError, Aws::Errors::MissingCredentialsError,
                  Seahorse::Client::NetworkingError].freeze

    USAGE = <<~TEXT
      使い方:
        ruby bin/ami_publish run      --environment ENV --version vX.Y.Z [--verified manual|automated]
                                      [--health-check true|false] [--pipeline-execution-id ID] [--output-env-file PATH]
        ruby bin/ami_publish plan     --environment ENV --version vX.Y.Z [--health-check true|false]
        ruby bin/ami_publish rollback --environment ENV --to-version vX.Y.Z [--dry-run] [--output-env-file PATH]

        run       リリース用インスタンスから AMI を作成し、起動テンプレートのスタックを更新する
        plan      run と同じ流れを、AWS に書き込まずに確認する（dry-run）
        rollback  起動テンプレートを、公開済みの前のバージョンの AMI に戻す

      共通オプション:
        --config PATH          設定値ファイル（既定: config/ami_publish.yml）
        --health-check VALUE   false でヘルスチェックを省略する（既定: true）
    TEXT

    def initialize(argv, stdout: $stdout, stderr: $stderr, client_factory: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @client_factory = client_factory
      @logger = StructuredLogger.new(output: stdout)
    end

    def run
      subcommand = @argv.shift
      return usage_error("サブコマンドを指定する") unless SUBCOMMANDS.include?(subcommand)

      options = parse_options(subcommand)
      configuration = Configuration.load(path: options[:config], environment_name: options[:environment])
      clients = @client_factory&.call(configuration) || AwsClientFactory.new(region: configuration.aws_region)
      execute(subcommand, options, configuration, clients)
      0
    rescue ConfigurationError, OptionParser::ParseError => e
      usage_error(e.message)
    rescue StepFailedError => e
      @logger.error("failed", message: e.message)
      1
    rescue *AWS_ERRORS => e
      @logger.error("aws_error", error_class: e.class.name, message: e.message)
      3
    end

    private

    # ステップが使う部品と実行の値を context に入れ、コマンド（interactor の Organizer）を実行する
    def execute(subcommand, options, configuration, clients)
      parts = { configuration: configuration, clients: clients, logger: @logger,
                output_env_file: options[:output_env_file] }
      if subcommand == "rollback"
        Commands::RollbackCommand.call!(**parts, version: options[:to_version], dry_run: options[:dry_run])
      else
        Commands::PublishCommand.call!(**parts, version: options[:version], verified: options[:verified],
                                                pipeline_execution_id: options[:pipeline_execution_id],
                                                dry_run: subcommand == "plan",
                                                health_check: options[:health_check] == "true")
      end
    end

    def parse_options(subcommand)
      options = { config: "config/ami_publish.yml", verified: "manual", health_check: "true", dry_run: false }
      option_parser(options).parse!(@argv)
      raise ConfigurationError, "余分な引数がある: #{@argv.join(' ')}" unless @argv.empty?

      validate_options(subcommand, options)
      options[:pipeline_execution_id] ||= "local-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
      options
    end

    def option_parser(options)
      OptionParser.new do |parser|
        parser.on("--config PATH") { |value| options[:config] = value }
        parser.on("--environment NAME") { |value| options[:environment] = value }
        parser.on("--version VERSION") { |value| options[:version] = value }
        parser.on("--to-version VERSION") { |value| options[:to_version] = value }
        parser.on("--verified VALUE") { |value| options[:verified] = value }
        parser.on("--health-check VALUE") { |value| options[:health_check] = value }
        parser.on("--pipeline-execution-id ID") { |value| options[:pipeline_execution_id] = value unless value.empty? }
        parser.on("--output-env-file PATH") { |value| options[:output_env_file] = value }
        parser.on("--dry-run") { options[:dry_run] = true }
      end
    end

    def validate_options(subcommand, options)
      if subcommand == "rollback"
        require_version(options[:to_version], "--to-version")
        raise ConfigurationError, "rollback では --version ではなく --to-version を指定する" if options[:version]
      else
        require_version(options[:version], "--version")
        unless %w[true false].include?(options[:health_check])
          raise ConfigurationError, "--health-check は true / false のどちらかにする"
        end
        unless VERIFIED_VALUES.include?(options[:verified])
          raise ConfigurationError, "--verified は #{VERIFIED_VALUES.join(' / ')} のどちらかにする"
        end
        raise ConfigurationError, "#{subcommand} では --dry-run ではなく plan を使う" if options[:dry_run]
      end
    end

    def require_version(value, option)
      raise ConfigurationError, "#{option} を指定する（例: v1.2.3）" if value.to_s.empty?
      return if Configuration::VERSION_PATTERN.match?(value)

      raise ConfigurationError, "#{option} の形式が不正: #{value}（例: v1.2.3）"
    end

    def usage_error(message)
      @stderr.puts("エラー: #{message}")
      @stderr.puts
      @stderr.puts(USAGE)
      2
    end
  end
end
