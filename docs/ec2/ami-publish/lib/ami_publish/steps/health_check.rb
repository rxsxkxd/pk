# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 4: SSM ドキュメント（ヘルスチェック）をリリース用インスタンスで実行し、
    # 再起動後にアプリが自動で起動して応答するかを確認する。
    # 失敗した場合は、AMI とスナップショットを削除して失敗にする（決定事項 D5）。
    # 原因の調査は、起動したまま残るリリース用インスタンスで行う。
    class HealthCheck < BaseStep
      TERMINAL_STATUSES = %w[Success Cancelled TimedOut Failed].freeze
      OUTPUT_EXCERPT_LENGTH = 1000

      def call
        return if skipped_without_health_check?("health_check_skipped")

        if context.image_id.nil?
          logger.info("health_check_skipped", reason: "dry-run のため AMI を作成していない")
          return
        end

        command_id = send_health_check(context)
        invocation = wait_for_invocation(command_id)
        return logger.info("health_check_passed", command_id: command_id) if invocation.status == "Success"

        fail_with(context, "ヘルスチェックが失敗した（#{invocation.status}）: " \
                           "#{invocation.standard_error_content.to_s[0, OUTPUT_EXCERPT_LENGTH]}")
      rescue Poller::TimeoutError => e
        fail_with(context, e.message)
      end

      private

      def send_health_check(context)
        response = clients.ssm.send_command(
          instance_ids: [configuration.release_instance_id],
          document_name: health_check_document_name,
          comment: "ami-publish health check #{context.version}",
          cloud_watch_output_config: {
            cloud_watch_output_enabled: true,
            cloud_watch_log_group_name: log_group_name
          }
        )
        response.command.command_id
      end

      def wait_for_invocation(command_id)
        invocation = nil
        progress = progress_logger("ヘルスチェック")
        poller.wait(timeout_seconds: configuration.health_check_timeout_seconds, description: "ヘルスチェック") do
          invocation = clients.ssm.get_command_invocation(command_id: command_id,
                                                          instance_id: configuration.release_instance_id)
          terminal = TERMINAL_STATUSES.include?(invocation.status)
          progress.report { { command_id: command_id, status: invocation.status } } unless terminal
          terminal
        rescue Aws::SSM::Errors::InvocationDoesNotExist
          progress.report { { command_id: command_id, status: "（実行結果が未登録）" } }
          false # 送信直後は実行結果がまだ登録されていない
        end
        invocation
      end

      def fail_with(context, message)
        image_cleanup.delete(context.image_id, reason: "再起動後のヘルスチェックが失敗した")
        raise StepFailedError, message
      end
    end
  end
end
