# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 6: 結果を出力する。
    #   - AMI にタグ Status=published と HealthCheck=passed / skipped を付ける
    #     （Status はロールバックの戻し先を探すときに使う。context.tag_image が false なら付けない）
    #   - AMI_ID と LAUNCH_TEMPLATE_VERSION をファイルに書き出す（buildspec が exported-variables として公開する）
    class PublishOutputs < BaseStep
      SAFE_VALUE_PATTERN = /\A[A-Za-z0-9._:-]+\z/

      def call
        if context.dry_run
          logger.info("publish_outputs_planned", tag_image: tag_image?, output_env_file: output_env_file)
          return
        end

        tag_published(context) if tag_image?
        write_env_file(context) if output_env_file
        logger.info("published", image_id: context.image_id, version: context.version,
                                 launch_template_version: context.launch_template_version)
      end

      private

      def tag_image? = context.tag_image != false
      def output_env_file = context.output_env_file

      # HealthCheck タグで、ヘルスチェックを行ったか（passed）省略したか（skipped）を残す
      def tag_published(context)
        health_check = health_check? ? "passed" : "skipped"
        # [変更] AMI のタグを Status=published、HealthCheck=passed / skipped にする
        clients.ec2.create_tags(resources: [context.image_id], tags: [{ key: "Status", value: "published" },
                                                                      { key: "HealthCheck", value: health_check }])
      end

      def write_env_file(context)
        values = { "AMI_ID" => context.image_id, "LAUNCH_TEMPLATE_VERSION" => context.launch_template_version }
        values.each do |key, value|
          raise StepFailedError, "出力値 #{key} が不正: #{value.inspect}" unless SAFE_VALUE_PATTERN.match?(value.to_s)
        end
        File.write(output_env_file, values.map { |key, value| "#{key}=#{value}\n" }.join)
      end
    end
  end
end
