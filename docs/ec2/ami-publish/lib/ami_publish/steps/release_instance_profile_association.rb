# frozen_string_literal: true

module AmiPublish
  module Steps
    # リリース用インスタンスへのインスタンスプロファイルの紐付けと解除の共通部分
    # （AttachReleaseInstanceProfile と DetachReleaseInstanceProfile が使う）。
    #
    # 紐付けるのは、リリース用インスタンスの IAM ロールのスタックのインスタンスプロファイル
    # （パイプラインのスタックの出力 ReleaseInstanceProfileArn）。設計は docs/ec2/notes/ami-publish/ami-publish-health-check-role-association-flow.md。
    # 紐付けたかどうかは context.profile_attached で受け渡す。
    module ReleaseInstanceProfileAssociation
      # 紐付け・解除が完了するまでの待機時間の上限（通常は数秒で終わる）
      ASSOCIATION_TIMEOUT_SECONDS = 300

      private

      def instance_id
        configuration.release_instance_id
      end

      # このスタックのインスタンスプロファイルの紐付けをすべて解除し、解除が完了するまで待つ。
      def detach
        active_profile_associations
          .select { |association| association.iam_instance_profile.arn == release_instance_profile_arn }
          .each do |association|
            # [変更] リリース用インスタンスからインスタンスプロファイルの紐付けを解除する
            clients.ec2.disassociate_iam_instance_profile(association_id: association.association_id)
            wait_for_state(association.association_id, "disassociated", "インスタンスプロファイルの紐付けの解除")
            logger.info("profile_disassociated", instance_id: instance_id, association_id: association.association_id)
          end
        context.profile_attached = false
      end

      # 紐付けの状態が target（associated / disassociated）になるまで待つ。
      # 解除の完了後は、紐付けが一覧から消えることもあるので、見つからなければ disassociated とみなす。
      def wait_for_state(association_id, target, description)
        progress = progress_logger(description)
        poller.wait(timeout_seconds: ASSOCIATION_TIMEOUT_SECONDS, description: description) do
          state = association_state(association_id) || "disassociated"
          next true if state == target
          if target == "associated" && state == "disassociated"
            raise StepFailedError, "紐付けが完了せずに解除された（#{association_id}）"
          end

          progress.report { { instance_id: instance_id, association_id: association_id, state: state } }
          false
        end
      end

      def association_state(association_id)
        clients.ec2.describe_iam_instance_profile_associations(association_ids: [association_id])
               .iam_instance_profile_associations.first&.state
      rescue Aws::EC2::Errors::InvalidAssociationIDNotFound
        nil
      end

      def manual_detach_command
        "aws ec2 describe-iam-instance-profile-associations --filters Name=instance-id,Values=#{instance_id} " \
          "で紐付けの ID を調べ、aws ec2 disassociate-iam-instance-profile --association-id <紐付けの ID> を実行する"
      end
    end
  end
end
