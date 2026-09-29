# frozen_string_literal: true

module AmiPublish
  module Steps
    # 各ステップの共通部分。ステップは call(context) で処理し、結果を context に書き込む。
    class BaseStep
      def initialize(configuration:, clients:, logger:, poller: nil, image_cleanup: nil)
        @configuration = configuration
        @clients = clients
        @logger = logger
        @poller = poller || Poller.new(interval_seconds: configuration.poll_interval_seconds)
        @image_cleanup = image_cleanup || ImageCleanup.new(ec2: clients.ec2, logger: logger)
      end

      private

      attr_reader :configuration, :clients, :logger, :poller, :image_cleanup

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
      def skipped_without_health_check?(context, event)
        return false if context.health_check?

        logger.info(event, reason: "ヘルスチェックを省略する実行のため（--health-check false）")
        true
      end

      # SSM から見たリリース用インスタンスの情報（PingStatus など）。SSM の管理対象でなければ nil。
      def ssm_instance_information
        filters = [{ key: "InstanceIds", values: [configuration.release_instance_id] }]
        clients.ssm.describe_instance_information(filters: filters).instance_information_list.first
      end

      def application_tag_filters
        [{ name: "tag:App", values: [configuration.application_name] }]
      end
    end
  end
end
