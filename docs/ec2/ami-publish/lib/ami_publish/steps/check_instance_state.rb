# frozen_string_literal: true

module AmiPublish
  module Steps
    # 開始前の確認: リリース用インスタンスの状態を確かめ、開始時に起動中か停止中かを記録する。
    #
    #   起動中（running）: AMI 作成時に再起動し、再起動後に SSM の接続とヘルスチェックを確認する（従来どおり）
    #   停止中（stopped）: 停止したまま AMI を作成し（再起動なし）、その後にインスタンスを起動して確認する
    #
    # 起動処理中（pending）・停止処理中（stopping）なら、状態が落ち着くまで待つ。
    # 終了済みなど、それ以外の状態では AWS を何も変更せずに失敗にする。
    #
    # あわせて、SSM の管理対象になっているかを確かめる（ステップ 3・4 で SSM を使うため）。
    #   起動中: SSM Agent が Online になるまで待つ（起動直後の一時的な未接続を吸収する）
    #   停止中: 接続はしていなくてよいが、SSM の管理対象として登録されていること
    # 確かめられなければ、AMI を作らず、インスタンスも再起動せずに失敗にする。
    # ヘルスチェックを省略する実行では、SSM を使わないため、この確認も行わない。
    class CheckInstanceState < BaseStep
      STABLE_STATES = %w[running stopped].freeze
      TRANSITIONAL_STATES = %w[pending stopping].freeze

      def call(context)
        state = wait_for_stable_state
        verify_managed_by_ssm(state) unless skipped_without_health_check?(context, "ssm_check_skipped")
        context.instance_state_at_start = state
        logger.info("instance_state_checked", instance_id: instance_id, state: state, flow: flow_description(state))
      end

      private

      def instance_id
        configuration.release_instance_id
      end

      def wait_for_stable_state
        state = nil
        progress = progress_logger("リリース用インスタンスの状態が落ち着くまで")
        poller.wait(timeout_seconds: configuration.instance_online_timeout_seconds,
                    description: "リリース用インスタンスの状態の確定") do
          state = current_state
          next true if STABLE_STATES.include?(state)
          unless TRANSITIONAL_STATES.include?(state)
            raise StepFailedError, "リリース用インスタンス #{instance_id} の状態が #{state} のため、AMI を作成できない"
          end

          progress.report { { instance_id: instance_id, state: state } }
          false
        end
        state
      rescue Poller::TimeoutError => e
        raise StepFailedError, "#{e.message}（状態: #{state}）"
      end

      def verify_managed_by_ssm(state)
        information = nil
        if state == "running"
          progress = progress_logger("SSM Agent の接続（AMI 作成前の確認）")
          poller.wait(timeout_seconds: configuration.instance_online_timeout_seconds,
                      description: "AMI 作成前の SSM Agent の接続確認") do
            information = ssm_instance_information
            next true if information&.ping_status == "Online"

            progress.report { { instance_id: instance_id, ping_status: ping_status_label(information) } }
            false
          end
        else
          information = ssm_instance_information
          raise StepFailedError, not_managed_message(information) unless information
        end
        logger.info("ssm_managed", instance_id: instance_id, ping_status: information.ping_status)
      rescue Poller::TimeoutError
        raise StepFailedError, not_managed_message(information)
      end

      def ping_status_label(information)
        information&.ping_status || "（SSM に未登録）"
      end

      def not_managed_message(information)
        problem = if information
                    "SSM Agent が接続していない（状態: #{information.ping_status}）"
                  else
                    "SSM の管理対象になっていない（Fleet Manager に表示されない）"
                  end
        "リリース用インスタンス #{instance_id} は#{problem}。AMI は作成していない。" \
          "インスタンスプロファイルの AmazonSSMManagedInstanceCore、SSM Agent の起動、" \
          "SSM への経路（NAT ゲートウェイまたは VPC エンドポイント）を確認する"
      end

      def current_state
        reservations = clients.ec2.describe_instances(instance_ids: [instance_id]).reservations
        instance = reservations.flat_map(&:instances).first
        raise StepFailedError, "リリース用インスタンス #{instance_id} が見つからない" unless instance

        instance.state.name
      end

      def flow_description(state)
        if state == "running"
          "起動中: AMI 作成時に再起動し、再起動後に確認する"
        else
          "停止中: 停止したまま AMI を作成し、その後に起動して確認する（パイプラインでは停止に戻さない）"
        end
      end
    end
  end
end
