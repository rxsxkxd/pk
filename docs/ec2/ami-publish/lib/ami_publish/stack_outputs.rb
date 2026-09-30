# frozen_string_literal: true

module AmiPublish
  # AMI 公開パイプラインのスタックの出力。
  #
  # AMI 公開ツールは、パイプラインのスタックの名前だけを命名規則で決め、ほかの名前はこの出力から引く。
  #   LaunchTemplateStackName            起動テンプレートのスタック名
  #   HealthCheckDocumentName            ヘルスチェックの SSM ドキュメント名
  #   LogGroupName                       CodeBuild のログとヘルスチェックの出力の保存先
  # 前の 2 つは、パイプラインのスタックが他のスタックの Export から受け取って出力している。
  class StackOutputs
    def initialize(cloudformation:, stack_name:)
      @cloudformation = cloudformation
      @stack_name = stack_name
    end

    def fetch(key)
      outputs.fetch(key) do
        raise StepFailedError, "パイプラインのスタック #{@stack_name} に出力 #{key} がない。" \
                               "スタックが古い可能性がある（仕組みを再デプロイする）"
      end
    end

    private

    def outputs
      @outputs ||= @cloudformation.describe_stacks(stack_name: @stack_name).stacks.first
                                  .outputs.to_h { |output| [output.output_key, output.output_value] }
    rescue Aws::CloudFormation::Errors::ValidationError => e
      raise StepFailedError, "パイプラインのスタック #{@stack_name} が見つからない（#{e.message}）。" \
                             "命名規則どおりの名前でデプロイされているか確認する（generated/deploy/<環境>.sh up）"
    end
  end
end
