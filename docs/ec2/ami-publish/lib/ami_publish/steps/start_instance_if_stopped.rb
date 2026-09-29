# frozen_string_literal: true

module AmiPublish
  module Steps
    # 開始時に停止中だった場合だけ、ヘルスチェックのためにリリース用インスタンスを起動する（AMI の作成後）。
    #
    # AMI は停止中に作成済みなので、AMI と同じディスクの状態から OS を起動して確認することになる。
    # 起動したまま終わる。停止に戻すのはパイプラインの外で行う。
    # 起動できなかった場合は、確認できない AMI になるため、AMI とスナップショットを削除して失敗にする（決定事項 D5）。
    class StartInstanceIfStopped < BaseStep
      def call(context)
        # ヘルスチェックを省略するなら起動しない（停止したまま AMI を作って終わる）
        return if skipped_without_health_check?(context, "start_instance_skipped")

        unless context.instance_state_at_start == "stopped"
          logger.info("start_instance_skipped", reason: "開始時に起動中だったため（AMI 作成時の再起動で確認する）")
          return
        end
        if context.image_id.nil?
          logger.info("start_instance_planned", instance_id: instance_id)
          return
        end

        start_and_wait
        logger.info("instance_started", instance_id: instance_id)
      rescue Aws::Waiters::Errors::WaiterFailed, Aws::EC2::Errors::ServiceError => e
        image_cleanup.delete(context.image_id, reason: "確認のためのリリース用インスタンスの起動に失敗した")
        raise StepFailedError, "リリース用インスタンス #{instance_id} を起動できなかった: #{e.message}"
      end

      private

      def instance_id
        configuration.release_instance_id
      end

      def start_and_wait
        # [変更] リリース用インスタンスを起動する
        clients.ec2.start_instances(instance_ids: [instance_id])
        progress = progress_logger("リリース用インスタンスの起動")
        clients.ec2.wait_until(:instance_running, instance_ids: [instance_id]) do |waiter|
          configure_waiter(waiter, configuration.instance_online_timeout_seconds, progress: progress) do |response|
            { instance_id: instance_id, state: state_in(response) }
          end
        end
      end

      def state_in(response)
        reservation = response.data&.reservations&.first
        instance = reservation&.instances&.first
        instance&.state&.name
      end
    end
  end
end
