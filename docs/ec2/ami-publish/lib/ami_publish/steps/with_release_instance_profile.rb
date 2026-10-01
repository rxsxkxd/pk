# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 1a〜4a: ヘルスチェックのための区間だけ、リリース用インスタンスにインスタンスプロファイルを紐付ける。
    #
    # 紐付けるのは、リリース用インスタンスの IAM ロールのスタックのインスタンスプロファイル
    # （パイプラインのスタックの出力 ReleaseInstanceProfileArn）。リリース用インスタンスがロールを持つのは、
    # この区間（AMI の作成の直前からヘルスチェックの完了まで）だけにする。
    # 設計は docs/ec2/ami-publish-health-check-role-association-flow.md。
    #
    #   1a. 紐付け（AMI の作成の直前。AMI の作成時の再起動、または停止中だった場合の起動で、
    #       SSM Agent が起動時にロールの認証情報を取る）
    #   区間の中のステップ（AMI の作成 → AMI の待機 → 停止中だった場合の起動 → 接続待ち → ヘルスチェック）
    #   4a. 紐付けの解除（成功時）。失敗したら AMI は残して失敗にする（ヘルスチェックは通っているため）
    #   4x. 紐付けの解除（区間の中のどこかで失敗した場合）。必ず行う。AMI の削除は各ステップが行う（D5）
    #
    # CodeBuild のタイムアウトや強制終了でプロセスが止められた場合は、解除は動かない（紐付けが残る）。
    # 次の実行は、残った紐付けをそのまま使い、ヘルスチェックの後に解除する。
    # ヘルスチェックを省略する実行では、紐付けも解除も行わず、区間の中のステップだけを実行する。
    class WithReleaseInstanceProfile < BaseStep
      # 紐付け・解除が完了するまでの待機時間の上限（通常は数秒で終わる）
      ASSOCIATION_TIMEOUT_SECONDS = 300

      def initialize(steps:, **dependencies)
        super(**dependencies)
        @runner = StepRunner.new(logger: logger, steps: steps)
      end

      def call(context)
        return @runner.run(context) unless context.health_check?

        if context.dry_run
          logger.info("profile_association_planned", instance_id: instance_id,
                                                     instance_profile_arn: release_instance_profile_arn)
          return @runner.run(context)
        end

        attach
        run_attached(context)
      end

      private

      def instance_id
        configuration.release_instance_id
      end

      def run_attached(context)
        @runner.run(context)
      rescue StandardError
        detach_after_failure
        raise
      else
        detach_after_success
      end

      # 1a. 紐付け。このスタックのインスタンスプロファイルがすでに付いていれば（前回の異常終了の残り）、そのまま使う。
      def attach
        current = active_profile_associations
        if current.any? { |association| association.iam_instance_profile.arn == release_instance_profile_arn }
          logger.info("profile_association_reused", instance_id: instance_id,
                                                    instance_profile_arn: release_instance_profile_arn)
          return
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

      # 4a. 成功時の解除。失敗したら AMI は残す（同じ実行の再試行で AMI を再利用し、紐付けからやり直す）。
      def detach_after_success
        detach
      rescue Poller::TimeoutError, Aws::Errors::ServiceError => e
        raise StepFailedError, "ヘルスチェックは成功したが、インスタンスプロファイルの紐付けを解除できなかった" \
                               "（#{e.message}）。AMI は残している。同じ実行を再試行するか、手で解除する: #{manual_detach_command}"
      end

      # 4x. 失敗時の解除。解除の失敗はログに残すだけにし、元の失敗の原因を隠さない。
      def detach_after_failure
        detach
      rescue Poller::TimeoutError, Aws::Errors::ServiceError => e
        logger.error("profile_disassociate_failed", instance_id: instance_id, error_class: e.class.name,
                                                    message: e.message, manual_command: manual_detach_command)
      end

      def detach
        active_profile_associations
          .select { |association| association.iam_instance_profile.arn == release_instance_profile_arn }
          .each do |association|
            # [変更] リリース用インスタンスからインスタンスプロファイルの紐付けを解除する
            clients.ec2.disassociate_iam_instance_profile(association_id: association.association_id)
            wait_for_state(association.association_id, "disassociated", "インスタンスプロファイルの紐付けの解除")
            logger.info("profile_disassociated", instance_id: instance_id, association_id: association.association_id)
          end
      end

      # 紐付けの解除だけを試みる（紐付けの失敗の後始末）。失敗してもログに残すだけ。
      def disassociate_quietly(association_id)
        return unless association_id

        # [変更] 途中まで進んだ紐付けを解除する
        clients.ec2.disassociate_iam_instance_profile(association_id: association_id)
      rescue Aws::Errors::ServiceError => e
        logger.error("profile_disassociate_failed", instance_id: instance_id, association_id: association_id,
                                                    message: e.message, manual_command: manual_detach_command)
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
