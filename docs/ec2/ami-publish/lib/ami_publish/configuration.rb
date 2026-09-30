# frozen_string_literal: true

module AmiPublish
  # config/ami_publish.yml の 1 環境分の設定値。
  # 同じファイルを Go の仕組み生成ツールも読む。値の形式の詳細な検証は仕組み生成ツールが行い、
  # ここでは AMI 公開ツールが使う値の有無と基本的な形式だけを確認する。
  #
  # リソースの名前は application_name と環境名から自動で決める（下の「命名規則」）。
  # Go の仕組み生成ツール（internal/definitions/naming.go）も同じ規則で名前を決めている。
  # 規則を変えるときは両方を直し、両方のテストで同じ名前になることを確かめる。
  class Configuration
    VERSION_PATTERN = /\Av\d+\.\d+\.\d+\z/
    INSTANCE_ID_PATTERN = /\Ai-[0-9a-f]{8,17}\z/
    APPLICATION_NAME_PATTERN = /\A[a-z][a-z0-9-]*\z/

    attr_reader :environment_name, :aws_region, :application_name, :release_instance_id,
                :basic_auth_parameter_name, :ami_name_tag_prefix,
                :image_available_timeout_seconds, :progress_log_interval_seconds, :instance_online_timeout_seconds,
                :health_check_timeout_seconds, :stack_update_timeout_seconds, :poll_interval_seconds

    def self.load(path:, environment_name:)
      raise ConfigurationError, "設定値ファイルがない: #{path}" unless File.file?(path)
      raise ConfigurationError, "--environment を指定する" if environment_name.to_s.empty?

      environments = YAML.safe_load_file(path).fetch("environments", nil)
      raise ConfigurationError, "#{path} に environments がない" unless environments.is_a?(Hash)

      settings = environments[environment_name]
      unless settings.is_a?(Hash)
        raise ConfigurationError,
              "環境 #{environment_name} が #{path} にない（定義済み: #{environments.keys.join(', ')}）"
      end

      new(environment_name, settings)
    end

    def initialize(environment_name, settings)
      @environment_name = environment_name
      @aws_region = required(settings, "aws_region")
      @application_name = required(settings, "application_name", pattern: APPLICATION_NAME_PATTERN)
      @release_instance_id = required(settings, "release_instance_id", pattern: INSTANCE_ID_PATTERN)
      # AMI の Name タグの接頭辞（省略可。省略時は接頭辞なし）。形式の検証は Go の仕組み生成ツールが行う
      prefix = settings.dig("ami", "name_tag_prefix")
      @ami_name_tag_prefix = prefix.to_s.empty? ? nil : prefix.to_s
      # Basic 認証のパラメーター名（省略可。ヘルスチェックの許可の確認に使う）
      @basic_auth_parameter_name = settings.dig("health_check", "basic_auth_parameter_name")
      load_timeouts(settings)
    end

    # 命名規則（Go の internal/definitions/naming.go と同じ）

    # AMI 公開パイプラインのスタック（出力からスタック用サービスロールの ARN を取る）
    def pipeline_stack_name = "#{name_prefix}-ami-publish-pipeline"

    # CodeBuild のログと、ヘルスチェックの出力を保存する CloudWatch Logs のロググループ
    def log_group_name = "/#{application_name}/#{environment_name}/ami-publish"

    # 起動テンプレートのスタック
    def launch_template_stack_name = "#{name_prefix}-launch-template"

    # ヘルスチェックの SSM ドキュメント
    def health_check_document_name = "#{name_prefix}-health-check"

    private

    def name_prefix = "#{application_name}-#{environment_name}"

    def load_timeouts(settings)
      @image_available_timeout_seconds = positive_integer(settings, "timeouts", "image_available_seconds")
      @instance_online_timeout_seconds = positive_integer(settings, "timeouts", "instance_online_seconds")
      @health_check_timeout_seconds = positive_integer(settings, "timeouts", "health_check_seconds")
      @stack_update_timeout_seconds = positive_integer(settings, "timeouts", "stack_update_seconds")
      @poll_interval_seconds = positive_integer(settings, "timeouts", "poll_interval_seconds", allow_zero: true)
      @progress_log_interval_seconds =
        positive_integer(settings, "timeouts", "progress_log_interval_seconds", allow_zero: true)
    end

    def required(settings, *keys, pattern: nil)
      value = settings.dig(*keys)
      field = "environments.#{environment_name}.#{keys.join('.')}"
      raise ConfigurationError, "#{field} がない" if value.nil? || value.to_s.empty?
      raise ConfigurationError, "#{field} の形式が不正: #{value}" if pattern && !pattern.match?(value.to_s)

      value.to_s
    end

    def positive_integer(settings, *keys, allow_zero: false)
      value = settings.dig(*keys)
      minimum = allow_zero ? 0 : 1
      unless value.is_a?(Integer) && value >= minimum
        raise ConfigurationError,
              "environments.#{environment_name}.#{keys.join('.')} は #{minimum} 以上の整数にする"
      end

      value
    end
  end
end
