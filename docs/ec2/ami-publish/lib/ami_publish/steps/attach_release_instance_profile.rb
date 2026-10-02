# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 1a: AMI の作成の直前に、リリース用インスタンスにインスタンスプロファイルを紐付ける。
    #
    # AMI の作成時の再起動、または停止中だった場合の起動で、SSM Agent が起動時にロールの認証情報を取る。
    # このスタックのインスタンスプロファイルがすでに付いていれば（前回の異常終了の残り）、そのまま使う。
    # ヘルスチェックを省略する実行と dry-run では紐付けない。
    #
    # 後のステップが失敗すると、interactor がこのステップの rollback を呼ぶ（4x: 失敗時の解除）。
    # 成功時の解除は DetachReleaseInstanceProfile が行う。CodeBuild のタイムアウトや強制終了でプロセスが
    # 止められた場合は、どちらも動かない（紐付けが残り、次の実行で解除される）。
    class AttachReleaseInstanceProfile < BaseStep
      include ReleaseInstanceProfileAssociation

      def call
        return if skipped_without_health_check?("profile_association_skipped")
        if context.dry_run
          return logger.info("profile_association_planned", instance_id: instance_id,
                                                            instance_profile_arn: release_instance_profile_arn)
        end

        attach
        context.profile_attached = true
      end

      # 4x. 後のステップが失敗したときの解除。解除の失敗はログに残すだけにし、元の失敗の原因を隠さない。
      def rollback
        detach if context.profile_attached
      rescue StandardError => e
        logger.error("profile_disassociate_failed", instance_id: instance_id, error_class: e.class.name,
                                                    message: e.message, manual_command: manual_detach_command)
      end

      private

      def attach
        current = active_profile_associations
        if current.any? { |association| association.iam_instance_profile.arn == release_instance_profile_arn }
          return logger.info("profile_association_reused", instance_id: instance_id,
                                                           instance_profile_arn: release_instance_profile_arn)
        end
        unless current.empty?
          raise StepFailedError, "リリース用インスタンス #{instance_id} に、別のインスタンスプロファイルが紐付いている。" \
                                 "AMI は作成していない"
        end

        associate_and_wait
      end

      def associate_and_wait
        # [変更] リリース用インスタンスにインスタンスプロファイルを紐付ける
        association = clients.ec2.associate_iam_instance_profile(
          instance_id: instance_id, iam_instance_profile: { arn: release_instance_profile_arn }
        ).iam_instance_profile_association
        wait_for_state(association.association_id, "associated", "インスタンスプロファイルの紐付け")
        logger.info("profile_associated", instance_id: instance_id, association_id: association.association_id,
                                          instance_profile_arn: release_instance_profile_arn)
      rescue Poller::TimeoutError, StepFailedError => e
        disassociate_quietly(association&.association_id)
        raise StepFailedError, "リリース用インスタンス #{instance_id} にインスタンスプロファイルを紐付けられなかった。" \
                               "AMI は作成していない: #{e.message}"
      end

      # 途中まで進んだ紐付けの解除だけを試みる（紐付けの失敗の後始末）。失敗してもログに残すだけ。
      def disassociate_quietly(association_id)
        return unless association_id

        # [変更] 途中まで進んだ紐付けを解除する
        clients.ec2.disassociate_iam_instance_profile(association_id: association_id)
      rescue Aws::Errors::ServiceError => e
        logger.error("profile_disassociate_failed", instance_id: instance_id, association_id: association_id,
                                                    message: e.message, manual_command: manual_detach_command)
      end
    end
  end
end
