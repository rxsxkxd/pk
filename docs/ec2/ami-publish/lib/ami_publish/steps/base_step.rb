# frozen_string_literal: true

module AmiPublish
  module Steps
    # 各ステップの共通部分。ステップは interactor（gem）の Interactor で、call で処理し、結果を context に書き込む。
    #
    # context（Interactor::Context）には、実行の値（version、dry_run、image_id など）と、ステップが使う部品
    # （configuration、clients、logger。テストでは poller・image_cleanup・pipeline_outputs も差し替えられる）を入れる。
    # ステップの並びは Commands の Organizer が決める。後のステップが失敗すると、interactor が実行済みのステップの
    # rollback を逆順に呼ぶ。
    class BaseStep
      include Interactor

      # ステップごとに開始・終了・失敗と所要時間をログに出す。
      # interactor の around フックはクラスごとに持つ（子クラスに引き継がれない）ので、子クラスの定義時に付ける。
      def self.inherited(subclass)
        super
        subclass.around(:log_step)
      end

      private

      def configuration = context.configuration
      def clients = context.clients
      def logger = context.logger

      def pipeline_outputs
        context.pipeline_outputs ||= StackOutputs.new(cloudformation: clients.cloudformation,
                                                      stack_name: configuration.pipeline_stack_name)
      end

      def poller = context.poller ||= Poller.new(interval_seconds: configuration.poll_interval_seconds)
      def image_cleanup = context.image_cleanup ||= ImageCleanup.new(ec2: clients.ec2, logger: logger)

      # 既定ではヘルスチェックを行う（明示的に false を指定したときだけ省略する）
      def health_check? = context.health_check != false

      def log_step(step)
        name = self.class.name.split("::").last
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        logger.info("step_started", step: name, dry_run: context.dry_run)
        step.call
        logger.info("step_finished", step: name, duration_seconds: elapsed_since(started))
      rescue StandardError => e
        logger.error("step_failed", step: name, error_class: e.class.name, message: e.message,
                                    duration_seconds: elapsed_since(started))
        raise
      end

      def elapsed_since(started) = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

      # 他のスタックの名前などは、パイプラインのスタックの出力から引く（命名規則では決めない）
      def launch_template_stack_name = pipeline_outputs.fetch("LaunchTemplateStackName")
      def health_check_document_name = pipeline_outputs.fetch("HealthCheckDocumentName")
      def log_group_name = pipeline_outputs.fetch("LogGroupName")
      # ヘルスチェックの区間だけリリース用インスタンスに紐付けるロールとインスタンスプロファイル
      def release_instance_role_arn = pipeline_outputs.fetch("ReleaseInstanceRoleArn")
      def release_instance_profile_arn = pipeline_outputs.fetch("ReleaseInstanceProfileArn")

      # AWS SDK の待機処理（waiter）の設定。待機時間の上限を確認間隔で割った回数だけ確認する。
      # progress を渡すと、確認のたびに進捗を出す（ログの項目はブロックが直前のレスポンスから作る）。
      def configure_waiter(waiter, timeout_seconds, progress: nil, &fields)
        interval = configuration.poll_interval_seconds
        waiter.delay = interval
        waiter.max_attempts = interval.zero? ? 3 : (timeout_seconds.to_f / interval).ceil
        return unless progress

        waiter.before_wait do |_attempts, response|
          progress.report { fields ? fields.call(response) : {} }
        end
      end

      # 時間のかかる待機処理の進捗を、timeouts.progress_log_interval_seconds ごとにログに出す。
      def progress_logger(description)
        ProgressLogger.new(logger: logger, description: description,
                           interval_seconds: configuration.progress_log_interval_seconds)
      end

      # ヘルスチェックを省略する実行なら、理由をログに出して true を返す（ステップの先頭で使う）
      def skipped_without_health_check?(event)
        return false if health_check?

        logger.info(event, reason: "ヘルスチェックを省略する実行のため（--health-check false）")
        true
      end

      # SSM から見たリリース用インスタンスの情報（PingStatus など）。SSM の管理対象でなければ nil。
      def ssm_instance_information
        filters = [{ key: "InstanceIds", values: [configuration.release_instance_id] }]
        clients.ssm.describe_instance_information(filters: filters).instance_information_list.first
      end

      # リリース用インスタンスの、有効な（紐付け中・紐付け済みの）インスタンスプロファイルの紐付け。
      # インスタンスに付けられるインスタンスプロファイルは 1 つだけなので、通常は 0 件か 1 件。
      def active_profile_associations
        filters = [{ name: "instance-id", values: [configuration.release_instance_id] }]
        clients.ec2.describe_iam_instance_profile_associations(filters: filters)
               .iam_instance_profile_associations
               .select { |association| %w[associating associated].include?(association.state) }
      end

      def application_tag_filters
        [{ name: "tag:App", values: [configuration.application_name] }]
      end
    end
  end
end
