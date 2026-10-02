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
    # あわせて、インスタンスプロファイルの紐付けを確かめる。AMI 公開ツールは、ヘルスチェックの区間だけ
    # リリース用インスタンスの IAM ロールのスタックのインスタンスプロファイルを紐付けるため、紐付けは次のどちらかであること。
    #   なし: 通常の状態
    #   このスタックのインスタンスプロファイル: 前回の実行が異常終了して残ったもの（そのまま使い、ヘルスチェックの後に解除する）
    # 別のインスタンスプロファイルが付いていれば、入れ替えずに失敗にする（AWS は何も変更しない）。
    # SSM の管理対象かは、紐付け前は判定できないため確かめない（AMI の作成後の接続待ちで分かる）。
    # ヘルスチェックを省略する実行では、紐付けを行わないため、この確認も行わない。
    class CheckInstanceState < BaseStep
      STABLE_STATES = %w[running stopped].freeze
      TRANSITIONAL_STATES = %w[pending stopping].freeze

      def call
        state = wait_for_stable_state
        verify_profile_association unless skipped_without_health_check?("profile_association_check_skipped")
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

      def verify_profile_association
        associations = active_profile_associations
        others = associations.reject do |association|
          association.iam_instance_profile.arn == release_instance_profile_arn
        end
        unless others.empty?
          raise StepFailedError, "リリース用インスタンス #{instance_id} に、別のインスタンスプロファイル " \
                                 "#{others.map { |association| association.iam_instance_profile.arn }.join(', ')} " \
                                 "が紐付いている。AMI は作成していない。AMI 公開パイプラインはヘルスチェックの区間だけ " \
                                 "#{release_instance_profile_arn} を紐付けるため、別のインスタンスプロファイルは入れ替えない"
        end
        if associations.empty?
          logger.info("profile_association_checked", instance_id: instance_id, associated: false)
        else
          logger.info("profile_association_left", instance_id: instance_id,
                                                  instance_profile_arn: release_instance_profile_arn,
                                                  message: "前回の実行で紐付けたまま残っている。そのまま使い、ヘルスチェックの後に解除する")
        end
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
