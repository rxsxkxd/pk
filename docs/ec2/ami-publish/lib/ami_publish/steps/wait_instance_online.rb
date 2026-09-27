# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 3: AMI 作成時の再起動の後、リリース用インスタンスの SSM Agent が接続（Online）するまで待つ。
    # 待機時間を過ぎた場合は、AMI とスナップショットを削除して失敗にする（決定事項 D5）。
    class WaitInstanceOnline < BaseStep
      def call(context)
        if context.image_id.nil?
          logger.info("wait_instance_online_skipped", reason: "dry-run のため AMI を作成していない")
          return
        end

        poller.wait(timeout_seconds: configuration.instance_online_timeout_seconds,
                    description: "リリース用インスタンスの SSM Agent の接続") do
          ping_status == "Online"
        end
        logger.info("instance_online", instance_id: configuration.release_instance_id)
      rescue Poller::TimeoutError => e
        image_cleanup.delete(context.image_id, reason: "再起動後に SSM Agent が接続しなかった")
        raise StepFailedError, e.message
      end

      private

      def ping_status
        filters = [{ key: "InstanceIds", values: [configuration.release_instance_id] }]
        clients.ssm.describe_instance_information(filters: filters).instance_information_list.first&.ping_status
      end
    end
  end
end
