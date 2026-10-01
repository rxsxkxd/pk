# frozen_string_literal: true

module AmiPublish
  module Commands
    # run / plan: AMI を作成し、起動テンプレートのスタックを更新する。
    # 開始時にリリース用インスタンスが停止中なら、停止したまま AMI を作成し、確認のために起動する（起動したまま終わる）。
    # リリース用インスタンスには、AMI の作成の直前からヘルスチェックの完了までだけ、インスタンスプロファイルを紐付ける
    # （WithReleaseInstanceProfile。区間の中で失敗しても必ず解除する）。
    class PublishCommand
      def initialize(configuration:, clients:, logger:, output_env_file: nil)
        # パイプラインのスタックの出力は、ステップ間で共有する（取得は 1 回）
        pipeline_outputs = StackOutputs.new(cloudformation: clients.cloudformation,
                                            stack_name: configuration.pipeline_stack_name)
        dependencies = { configuration: configuration, clients: clients, logger: logger,
                         pipeline_outputs: pipeline_outputs }
        @logger = logger
        # インスタンスプロファイルを紐付けている区間のステップ
        attached_steps = [
          Steps::CreateImage.new(**dependencies),
          Steps::WaitImageAvailable.new(**dependencies),
          Steps::StartInstanceIfStopped.new(**dependencies),
          Steps::WaitInstanceOnline.new(**dependencies),
          Steps::HealthCheck.new(**dependencies)
        ]
        @runner = StepRunner.new(logger: logger, steps: [
                                   Steps::CheckInstanceState.new(**dependencies),
                                   Steps::CheckReleaseInstancePermissions.new(**dependencies),
                                   Steps::WithReleaseInstanceProfile.new(steps: attached_steps, **dependencies),
                                   Steps::UpdateLaunchTemplateStack.new(**dependencies),
                                   Steps::PublishOutputs.new(output_env_file: output_env_file, **dependencies)
                                 ])
      end

      def run(context)
        @logger.info("publish_started", version: context.version, verified: context.verified,
                                        health_check: context.health_check?,
                                        pipeline_execution_id: context.pipeline_execution_id, dry_run: context.dry_run)
        @runner.run(context)
      end
    end
  end
end
