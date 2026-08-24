# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 3: AMI 作成時の再起動の後、リリース用インスタンスの SSM Agent が接続（Online）するまで待つ。
    # 待機時間を過ぎた場合は、AMI とスナップショットを削除して失敗にする（決定事項 D5）。
    # 待っている間は、SSM から見たインスタンスの状態（PingStatus）と最後に接続した時刻を進捗として出す。
    class WaitInstanceOnline < BaseStep
      def call
        return if skipped_without_health_check?("wait_instance_online_skipped")

        if context.image_id.nil?
          logger.info("wait_instance_online_skipped", reason: "dry-run のため AMI を作成していない")
          return
        end

        progress = progress_logger("再起動後の SSM Agent の接続")
        poller.wait(timeout_seconds: configuration.instance_online_timeout_seconds,
                    description: "リリース用インスタンスの SSM Agent の接続") do
          online?(progress)
        end
        logger.info("instance_online", instance_id: configuration.release_instance_id)
      rescue Poller::TimeoutError => e
        image_cleanup.delete(context.image_id, reason: "再起動後に SSM Agent が接続しなかった")
        raise StepFailedError, "#{e.message}。インスタンスプロファイルは紐付け済み。SSM Agent のインストールと自動起動、" \
                               "SSM への経路（NAT ゲートウェイまたは VPC エンドポイント）を確認する"
      end

      private

      def online?(progress)
        information = ssm_instance_information
        return true if information&.ping_status == "Online"

        progress.report do
          { instance_id: configuration.release_instance_id,
            ping_status: information&.ping_status || "（SSM に未登録）",
            last_ping: last_ping(information) }
        end
        false
      end

      def last_ping(information)
        time = information&.last_ping_date_time
        time&.utc&.iso8601
      end
    end
  end
end
