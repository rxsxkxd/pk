# frozen_string_literal: true

module AmiPublish
  module Commands
    # rollback: 起動テンプレートを、公開済みの前のバージョンの AMI に戻す（決定事項 D7）。
    # 起動テンプレートは直接変更せず、通常のリリースと同じく変更セットと差分の検証を通してスタックを更新する。
    class RollbackCommand
      include Interactor::Organizer

      before do
        context.change_set_prefix = "ami-publish-rollback"
        context.tag_image = false # 戻し先の AMI はすでに公開済み
        context.logger.info("rollback_started", to_version: context.version, dry_run: context.dry_run)
      end

      organize Steps::FindPublishedImage,
               Steps::UpdateLaunchTemplateStack,
               Steps::PublishOutputs
    end
  end
end
