# frozen_string_literal: true

module AmiPublish
  module Steps
    # ステップ 1: リリース用インスタンスから AMI を作成する。
    #
    # create-image は既定でインスタンスを再起動し、ファイルシステムの整合性を保った状態で AMI を作る。
    # インスタンスが停止中なら再起動は起きず、停止したままの状態で AMI を作る。
    # 同じパイプライン実行で作成済みの AMI（タグ PipelineExecutionId が一致）があれば、作らずに再利用する。
    class CreateImage < BaseStep
      UNUSABLE_STATES = %w[failed deregistered error invalid].freeze

      def call
        existing = find_existing_image(context.pipeline_execution_id)
        return reuse(existing, context) if existing

        timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
        name = image_name(context.version, timestamp)
        tags = image_tags(context, name_tag(context.version, timestamp))
        return plan_creation(name, tags) if context.dry_run

        context.image_id = create_image(name, tags, context.version)
      end

      private

      def reuse(existing, context)
        # dry-run では後続のステップに AMI を渡さない（ヘルスチェックの実行などを避ける）
        context.image_id = existing.image_id unless context.dry_run
        logger.info("image_reused", image_id: existing.image_id, state: existing.state,
                                    pipeline_execution_id: context.pipeline_execution_id, dry_run: context.dry_run)
      end

      def plan_creation(name, tags)
        logger.info("create_image_planned", instance_id: configuration.release_instance_id, name: name,
                                            tags: tags.to_h { |tag| [tag[:key], tag[:value]] })
      end

      def create_image(name, tags, version)
        # [変更] AMI を作成する（インスタンスが再起動する）
        response = clients.ec2.create_image(
          instance_id: configuration.release_instance_id,
          name: name,
          description: "#{configuration.application_name} #{version} (#{configuration.environment_name})",
          no_reboot: false,
          tag_specifications: [
            { resource_type: "image", tags: tags },
            { resource_type: "snapshot", tags: tags }
          ]
        )
        logger.info("image_creation_started", image_id: response.image_id, name: name,
                                              instance_id: configuration.release_instance_id)
        response.image_id
      end

      def find_existing_image(pipeline_execution_id)
        filters = application_tag_filters + [{ name: "tag:PipelineExecutionId", values: [pipeline_execution_id] }]
        clients.ec2.describe_images(owners: ["self"], filters: filters).images
               .reject { |image| UNUSABLE_STATES.include?(image.state) }
               .max_by(&:creation_date)
      end

      # AMI 名: <application_name>_<バージョン>_<日時>（環境は含めない。Name タグと同じくアンダーバーでつなぐ）。
      # AMI 名はアカウント・リージョンの中で一意で、作成後は変えられない。同じアカウントで環境ごとに分ける必要が
      # あれば、application_name に環境を含める（例: myapp-staging）
      def image_name(version, timestamp)
        [configuration.application_name, version, timestamp].join("_")
      end

      # Name タグ: <ami.name_tag_prefix>_<バージョン>_<日時>。接頭辞を省略した場合は <バージョン>_<日時>（環境は含めない）
      def name_tag(version, timestamp)
        [configuration.ami_name_tag_prefix, version, timestamp].compact.join("_")
      end

      # Name タグはコンソールの一覧の「Name」列に表示される
      def image_tags(context, name_tag)
        [
          { key: "Name", value: name_tag },
          { key: "App", value: configuration.application_name },
          { key: "Environment", value: configuration.environment_name },
          { key: "AppVersion", value: context.version },
          { key: "Verified", value: context.verified },
          { key: "PipelineExecutionId", value: context.pipeline_execution_id },
          { key: "Status", value: "creating" }
        ]
      end
    end
  end
end
