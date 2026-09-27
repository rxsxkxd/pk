# frozen_string_literal: true

module AmiPublish
  module Commands
    # run / plan: AMI を作成し、起動テンプレートのスタックを更新する（ステップ 1〜6）。
    class PublishCommand
      def initialize(configuration:, clients:, logger:, output_env_file: nil)
        dependencies = { configuration: configuration, clients: clients, logger: logger }
        @logger = logger
        @runner = StepRunner.new(logger: logger, steps: [
                                   Steps::CreateImage.new(**dependencies),
                                   Steps::WaitImageAvailable.new(**dependencies),
                                   Steps::WaitInstanceOnline.new(**dependencies),
                                   Steps::HealthCheck.new(**dependencies),
                                   Steps::UpdateLaunchTemplateStack.new(**dependencies),
                                   Steps::PublishOutputs.new(output_env_file: output_env_file, **dependencies)
                                 ])
      end

      def run(context)
        @logger.info("publish_started", version: context.version, verified: context.verified,
                                        pipeline_execution_id: context.pipeline_execution_id, dry_run: context.dry_run)
        @runner.run(context)
      end
    end
  end
end
