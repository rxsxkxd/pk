# frozen_string_literal: true

module AmiPublish
  module Steps
    # rollback 用: 戻し先のバージョンの、公開済み（Status=published）の AMI を探す。
    # 見つからない、または複数ある場合は、何も変更せずに失敗にする。
    class FindPublishedImage < BaseStep
      def call
        images = published_images(context.version)
        case images.size
        when 0
          raise StepFailedError, "バージョン #{context.version} の公開済み AMI が見つからない"
        when 1
          context.image_id = images.first.image_id
          logger.info("rollback_target_found", version: context.version, image_id: context.image_id)
        else
          raise StepFailedError, "バージョン #{context.version} の公開済み AMI が複数ある: " \
                                 "#{images.map(&:image_id).join(', ')}（タグを確認する）"
        end
      end

      private

      def published_images(version)
        filters = application_tag_filters + [
          { name: "tag:Environment", values: [configuration.environment_name] },
          { name: "tag:AppVersion", values: [version] },
          { name: "tag:Status", values: ["published"] },
          { name: "state", values: ["available"] }
        ]
        clients.ec2.describe_images(owners: ["self"], filters: filters).images
      end
    end
  end
end
