# frozen_string_literal: true

module AmiPublish
  module Commands
    # run / plan: AMI を作成し、起動テンプレートのスタックを更新する。
    # 開始時にリリース用インスタンスが停止中なら、停止したまま AMI を作成し、確認のために起動する（起動したまま終わる）。
    # リリース用インスタンスには、AMI の作成の直前からヘルスチェックの完了までだけ、インスタンスプロファイルを紐付ける。
    # 区間の中のどこかで失敗したら、interactor が AttachReleaseInstanceProfile の rollback を呼んで解除する。
    class PublishCommand
      include Interactor::Organizer

      before do
        context.logger.info("publish_started", version: context.version, verified: context.verified,
                                               health_check: context.health_check != false,
                                               pipeline_execution_id: context.pipeline_execution_id,
                                               dry_run: context.dry_run)
      end

      organize Steps::CheckInstanceState,
               Steps::CheckReleaseInstancePermissions,
               Steps::AttachReleaseInstanceProfile, # ここから紐付けの区間
               Steps::CreateImage,
               Steps::WaitImageAvailable,
               Steps::StartInstanceIfStopped,
               Steps::WaitInstanceOnline,
               Steps::HealthCheck,
               Steps::DetachReleaseInstanceProfile, # ここまで
               Steps::UpdateLaunchTemplateStack,
               Steps::PublishOutputs
    end
  end
end
