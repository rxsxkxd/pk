# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 2: AMI が使える状態（available）になるまで待つ。
    # failed になった、または待機時間を過ぎた場合は、AMI とスナップショットを削除して失敗にする。
    class WaitImageAvailable < BaseStep
      def call(context)
        if context.image_id.nil?
          logger.info("wait_image_available_skipped", reason: "dry-run のため AMI を作成していない")
          return
        end

        clients.ec2.wait_until(:image_available, image_ids: [context.image_id]) do |waiter|
          configure_waiter(waiter, configuration.image_available_timeout_seconds)
        end
        logger.info("image_available", image_id: context.image_id)
      rescue Aws::Waiters::Errors::WaiterFailed => e
        image_cleanup.delete(context.image_id, reason: "AMI が available にならなかった")
        raise StepFailedError, "AMI #{context.image_id} が available にならなかった: #{e.message}"
      end
    end
  end
end
