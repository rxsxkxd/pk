# frozen_string_literal: true

module AmiPublish
  module Commands
    # rollback: 起動テンプレートを、公開済みの前のバージョンの AMI に戻す（決定事項 D7）。
    # 起動テンプレートは直接変更せず、通常のリリースと同じく変更セットと差分の検証を通してスタックを更新する。
    class RollbackCommand
      def initialize(configuration:, clients:, logger:, output_env_file: nil)
        # パイプラインのスタックの出力は、ステップ間で共有する（取得は 1 回）
        pipeline_outputs = StackOutputs.new(cloudformation: clients.cloudformation,
                                            stack_name: configuration.pipeline_stack_name)
        dependencies = { configuration: configuration, clients: clients, logger: logger,
                         pipeline_outputs: pipeline_outputs }
        @logger = logger
        @runner = StepRunner.new(logger: logger, steps: [
                                   Steps::FindPublishedImage.new(**dependencies),
                                   Steps::UpdateLaunchTemplateStack.new(change_set_prefix: "ami-publish-rollback",
                                                                        **dependencies),
                                   Steps::PublishOutputs.new(output_env_file: output_env_file, tag_image: false,
                                                             **dependencies)
                                 ])
      end

      def run(context)
        @logger.info("rollback_started", to_version: context.version, dry_run: context.dry_run)
        @runner.run(context)
      end
    end
  end
end
