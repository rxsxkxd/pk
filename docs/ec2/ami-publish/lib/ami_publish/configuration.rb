# frozen_string_literal: true

module AmiPublish
  # config/ami_publish.yml の 1 環境分の設定値。
  # 同じファイルを Go の仕組み生成ツールも読む。値の形式の詳細な検証は仕組み生成ツールが行い、
  # ここでは AMI 公開ツールが使う値の有無と基本的な形式だけを確認する。
  class Configuration
    VERSION_PATTERN = /\Av\d+\.\d+\.\d+\z/
    INSTANCE_ID_PATTERN = /\Ai-[0-9a-f]{8,17}\z/

    attr_reader :environment_name, :aws_region, :application_name, :release_instance_id,
                :pipeline_stack_name, :log_group_name,
                :launch_template_stack_name, :health_check_document_name,
                :image_available_timeout_seconds, :instance_online_timeout_seconds,
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
      @application_name = required(settings, "application_name")
      @release_instance_id = required(settings, "release_instance_id", pattern: INSTANCE_ID_PATTERN)
      @pipeline_stack_name = required(settings, "pipeline", "stack_name")
      @log_group_name = required(settings, "pipeline", "log_group_name")
      @launch_template_stack_name = required(settings, "launch_template", "stack_name")
      @health_check_document_name = required(settings, "health_check", "ssm_document_name")
      load_timeouts(settings)
    end

    private

    def load_timeouts(settings)
      @image_available_timeout_seconds = positive_integer(settings, "timeouts", "image_available_seconds")
      @instance_online_timeout_seconds = positive_integer(settings, "timeouts", "instance_online_seconds")
      @health_check_timeout_seconds = positive_integer(settings, "timeouts", "health_check_seconds")
      @stack_update_timeout_seconds = positive_integer(settings, "timeouts", "stack_update_seconds")
      @poll_interval_seconds = positive_integer(settings, "timeouts", "poll_interval_seconds", allow_zero: true)
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
