# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 6: 結果を出力する。
    #   - AMI にタグ Status=published を付ける（ロールバックの戻し先を探すときに使う。tag_image: false なら付けない）
    #   - AMI_ID と LAUNCH_TEMPLATE_VERSION をファイルに書き出す（buildspec が exported-variables として公開する）
    class PublishOutputs < BaseStep
      SAFE_VALUE_PATTERN = /\A[A-Za-z0-9._:-]+\z/

      def initialize(output_env_file: nil, tag_image: true, **dependencies)
        super(**dependencies)
        @output_env_file = output_env_file
        @tag_image = tag_image
      end

      def call(context)
        if context.dry_run
          logger.info("publish_outputs_planned", tag_image: @tag_image, output_env_file: @output_env_file)
          return
        end

        tag_published(context.image_id) if @tag_image
        write_env_file(context) if @output_env_file
        logger.info("published", image_id: context.image_id, version: context.version,
                                 launch_template_version: context.launch_template_version)
      end

      private

      def tag_published(image_id)
        # [変更] AMI のタグを Status=published にする
        clients.ec2.create_tags(resources: [image_id], tags: [{ key: "Status", value: "published" }])
      end

      def write_env_file(context)
        values = { "AMI_ID" => context.image_id, "LAUNCH_TEMPLATE_VERSION" => context.launch_template_version }
        values.each do |key, value|
          raise StepFailedError, "出力値 #{key} が不正: #{value.inspect}" unless SAFE_VALUE_PATTERN.match?(value.to_s)
        end
        File.write(@output_env_file, values.map { |key, value| "#{key}=#{value}\n" }.join)
      end
    end
  end
end
