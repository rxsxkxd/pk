# frozen_string_literal: true

module AmiPublish
  # 失敗した AMI の登録を解除し、スナップショットを削除する（決定事項 D5）。
  # 後始末の失敗はログに残すだけにし、元の失敗の原因を隠さない。
  class ImageCleanup
    def initialize(ec2:, logger:)
      @ec2 = ec2
      @logger = logger
    end

    def delete(image_id, reason:)
      snapshot_ids = snapshot_ids_of(image_id)
      @ec2.deregister_image(image_id: image_id)
      snapshot_ids.each { |snapshot_id| @ec2.delete_snapshot(snapshot_id: snapshot_id) }
      @logger.info("image_deleted", image_id: image_id, snapshot_ids: snapshot_ids, reason: reason)
    rescue Aws::Errors::ServiceError => e
      @logger.error("image_delete_failed", image_id: image_id, reason: reason,
                                           error_class: e.class.name, message: e.message)
    end

    private

    def snapshot_ids_of(image_id)
      image = @ec2.describe_images(image_ids: [image_id]).images.first
      return [] unless image

      image.block_device_mappings.filter_map { |mapping| mapping.ebs&.snapshot_id }
    end
  end
end
