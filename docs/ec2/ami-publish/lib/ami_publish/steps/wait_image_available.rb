# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 2: AMI が使える状態（available）になるまで待つ。
    # failed になった、または待機時間を過ぎた場合は、AMI とスナップショットを削除して失敗にする。
    # 待っている間は、AMI の状態とスナップショットの進み具合（%）を進捗として出す。
    class WaitImageAvailable < BaseStep
      def call(context)
        if context.image_id.nil?
          logger.info("wait_image_available_skipped", reason: "dry-run のため AMI を作成していない")
          return
        end

        progress = progress_logger("AMI の作成（スナップショットの取得）")
        clients.ec2.wait_until(:image_available, image_ids: [context.image_id]) do |waiter|
          configure_waiter(waiter, configuration.image_available_timeout_seconds, progress: progress) do |response|
            image_progress(response)
          end
        end
        logger.info("image_available", image_id: context.image_id)
      rescue Aws::Waiters::Errors::WaiterFailed => e
        image_cleanup.delete(context.image_id, reason: "AMI が available にならなかった")
        raise StepFailedError, "AMI #{context.image_id} が available にならなかった: #{e.message}"
      end

      private

      def image_progress(response)
        image = response.data&.images&.first
        return {} unless image

        { image_id: image.image_id, state: image.state, snapshots: snapshot_progress(image) }
      end

      # 例: ["snap-0123 45%"]。取得に失敗しても待機処理は止めない。
      def snapshot_progress(image)
        snapshot_ids = image.block_device_mappings.filter_map { |mapping| mapping.ebs&.snapshot_id }
        return [] if snapshot_ids.empty?

        clients.ec2.describe_snapshots(snapshot_ids: snapshot_ids).snapshots
               .map { |snapshot| "#{snapshot.snapshot_id} #{snapshot.progress}" }
      rescue Aws::Errors::ServiceError
        []
      end
    end
  end
end
