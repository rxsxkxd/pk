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
    class CheckInstanceState < BaseStep
      STABLE_STATES = %w[running stopped].freeze
      TRANSITIONAL_STATES = %w[pending stopping].freeze

      def call(context)
        state = wait_for_stable_state
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
